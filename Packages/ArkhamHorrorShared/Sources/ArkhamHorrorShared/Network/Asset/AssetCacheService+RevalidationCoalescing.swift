import Foundation

/// Coalescing and cancellation for concurrent ``AssetCacheService``
/// revalidation requests. Completion (`completeRevalidation`) and the
/// transport/mutation pipeline (`performRevalidation`) a coalesced
/// revalidation ultimately runs are split into
/// `AssetCacheService+RevalidationCompletion.swift`, and disk/memory
/// assembly (`assembleRevalidatedAsset`) lives elsewhere — all purely to
/// keep each file within this package's file/type-length conventions;
/// still part of the single `AssetCacheService` actor's isolated state.
extension AssetCacheService {
    /// `existing`'s own historical publication stamp
    /// (``AssetMemoryCache/CachedAsset/durableClearEpoch``/
    /// ``AssetMemoryCache/CachedAsset/writeGeneration``) is the source of
    /// provenance to validate and, if it still checks out, reserve fresh
    /// authority from whenever `preIssuedAuthority` is `nil` — via
    /// ``resolveOrIssueRevalidation(expectedFormat:existing:slot:preIssuedAuthority:)``,
    /// called under this exact key's decision lock (see
    /// `AssetCacheService+IssuanceDecisionLock.swift`) so that check and
    /// reservation, and the join-or-create decision they gate, all happen
    /// as one atomic unit no other concurrent caller for this same key
    /// can interleave with. The bare memory-hit branch of
    /// ``revalidate(for:)`` calls this way: it holds no authority of its
    /// own at all before calling this (a prior revision of this code had
    /// it read/reserve authority unconditionally *before* calling this,
    /// discarding the result whenever this call ended up joining
    /// already-in-flight work instead — exactly the wasteful,
    /// occasionally-fencing duplicate reservation this lock now closes
    /// for that specific caller).
    ///
    /// `preIssuedAuthority`, when non-`nil`, is instead a durable
    /// clear-epoch/disk-write-generation snapshot the caller has *already*
    /// validated and reserved itself, at its own earlier synchronous
    /// decision point, for its own independent purpose — the
    /// validated-disk-hit branches of ``revalidate(for:)``
    /// (`AssetCacheService+DiskHit.swift`/`+RevalidationDiskFetch.swift`)
    /// each already hold their own separately-issued token, reserved
    /// purely for their own decode-authority re-check, *before* this is
    /// ever called, and deliberately carried straight through here
    /// unchanged rather than re-derived from `existing` a second time:
    /// those two callers pause (for a caller-installed test hook) between
    /// that reservation and this call, and re-deriving fresh authority
    /// here would move this operation's own issuance moment to *after*
    /// that pause, letting a clear/invalidate injected during it be
    /// missed by this check while still correctly caught by
    /// ``performRevalidation(_:)``'s own terminal authority check later —
    /// changing which typed error a race exactly there produces. Passed
    /// straight through to
    /// ``resolveOrIssueRevalidation(expectedFormat:existing:slot:preIssuedAuthority:)``,
    /// used only on its own "create fresh work" branch, exactly as before.
    ///
    /// Throws ``AssetError/revalidationProvenanceUnavailable`` (an
    /// internal-only signal — see its own doc comment) when
    /// `preIssuedAuthority` is `nil` and `existing`'s historical stamp is
    /// missing or no longer matches durable reality; every caller that
    /// can reach that branch (only the bare memory-hit branch) catches
    /// this case and falls back to its own uncached disk/fetch path
    /// exactly as if this had been a plain cache miss.
    func coalescedRevalidation(
        cacheKey: AssetCacheKey,
        url: URL,
        expectedFormat: AssetFormat,
        existing: CachedAsset,
        preIssuedAuthority: PreIssuedAuthority? = nil
    ) async throws -> CachedAsset {
        let waiterID = UUID()
        let (slot, resolved) = try await resolveRevalidationFetch(
            cacheKey: cacheKey,
            url: url,
            expectedFormat: expectedFormat,
            existing: existing,
            preIssuedAuthority: preIssuedAuthority
        )
        let fetchID = resolved.id
        let token = resolved.token

        return try await withTaskCancellationHandler {
            let result = await withCheckedContinuation { (continuation: AssetContinuation) in
                // See ``coalescedFetch(key:cacheKey:candidates:)`` for why
                // this synchronous registration, performed directly from
                // actor-isolated code, is race-free without extra locking.
                if inFlightRevalidation[slot]?.id == fetchID {
                    var fetch = inFlightRevalidation[slot]
                    fetch?.waiters[waiterID] = continuation
                    if let fetch {
                        setInFlightRevalidation(fetch, for: slot)
                    }
                } else {
                    continuation.resume(returning: .failure(CancellationError()))
                }
            }
            // `Task.isCancelled` is read inside
            // `finalizeRevalidationWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:)`
            // below, as the very last step before this waiter's outcome
            // is decided — see `finalizeFetchWaiterOutcome`'s doc
            // comment (`AssetCacheService+Coalescing.swift`) for why
            // folding the cancellation check, the authority re-check, and
            // this exact waiter's ledger acknowledgement into that single
            // synchronous actor method — rather than separate steps, as a
            // prior revision of this code had — is required.
            //
            // Reads the full per-key durable authority snapshot (epoch
            // *and* highest-issued ticket) rather than merely the epoch
            // — see ``AssetCacheService/isTokenAuthoritative(_:for:currentAuthority:)``'s
            // own doc comment for why an epoch-only check cannot detect
            // an independent sibling instance/process's own newer
            // issuance for this exact key.
            let currentAuthority = await currentDurableKeyAuthority(for: cacheKey)
            let resultIsSuccess = result.isCacheOperationSuccess
            let outcome = await finalizeRevalidationWaiterOutcome(
                slot,
                waiter: WaiterIdentity(fetchID: fetchID, waiterID: waiterID),
                token: token,
                currentAuthority: currentAuthority,
                resultIsSuccess: resultIsSuccess
            )
            switch outcome {
            case .cancelled:
                // See ``AssetCacheService+Coalescing.swift``'s
                // ``coalescedFetch(key:cacheKey:candidates:)`` for the
                // full reasoning this mirrors: a waiter resolved
                // directly by ``cancelRevalidationWaiter(_:fetchID:waiterID:)``
                // may already carry a typed `AssetError` in `result` (the
                // durable `.retiring` commit itself failed) rather than
                // plain cancellation -- never collapse that into
                // `CancellationError()`.
                if case let .failure(error) = result, !(error is CancellationError) {
                    throw error
                }
                throw CancellationError()
            case .stale:
                throw AssetError.staleOperation
            case let .retractionNotDurable(error):
                throw error
            case .failed, .delivered:
                return try result.get()
            }
        } onCancel: {
            Task {
                await self.cancelRevalidationWaiter(slot, fetchID: fetchID, waiterID: waiterID)
            }
        }
    }

    /// The join-or-issue decision for a revalidation, split out of
    /// ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:preIssuedAuthority:)``
    /// purely to keep that function's body within this package's
    /// `function_body_length` limit: derives `slot`, acquires this key's
    /// decision lock (see
    /// `AssetCacheService+IssuanceDecisionLock.swift`'s type-level doc
    /// comment for exactly what hazard that closes) around
    /// ``resolveOrIssueRevalidation(expectedFormat:existing:slot:preIssuedAuthority:)``,
    /// and releases it — on every path, including a thrown error — before
    /// returning.
    private func resolveRevalidationFetch(
        cacheKey: AssetCacheKey,
        url: URL,
        expectedFormat: AssetFormat,
        existing: CachedAsset,
        preIssuedAuthority: PreIssuedAuthority?
    ) async throws -> (slot: RevalidationSlot, resolved: ResolvedRevalidationFetch) {
        let etag = existing.metadata.etag
        let lastModified = existing.metadata.etag == nil ? existing.metadata.lastModified : nil
        let slot = RevalidationSlot(
            cacheKey: cacheKey,
            url: url,
            etag: etag,
            lastModified: lastModified
        )
        // Cancellation-aware: a caller cancelled while queued for this
        // key's decision lock (or in the narrow post-grant window -- see
        // ``acquireIssuanceDecisionLock(for:)``'s own doc comment) throws
        // here having never joined or reserved anything at all -- there
        // is nothing to release below in that case.
        try await acquireIssuanceDecisionLock(for: cacheKey)
        let resolved: ResolvedRevalidationFetch
        do {
            resolved = try await resolveOrIssueRevalidation(
                expectedFormat: expectedFormat,
                existing: existing,
                slot: slot,
                preIssuedAuthority: preIssuedAuthority
            )
        } catch {
            releaseIssuanceDecisionLock(for: cacheKey)
            throw error
        }
        releaseIssuanceDecisionLock(for: cacheKey)
        return (slot, resolved)
    }

    /// Mirrors `AssetCacheService+Coalescing.swift`'s
    /// ``AssetCacheService/cancelWaiter(_:fetchID:waiterID:)`` — including
    /// its retraction fix: retiring `fetch.token` (via
    /// ``retireIfCurrent(_:for:)``) only prevents a *future* mutation
    /// this now-doomed revalidation might otherwise still attempt; it
    /// does nothing about a `publish(_:asset:token:)`/`touch(_:asset:token:)`
    /// call the revalidation's own body already ran to completion,
    /// strictly before this exact cancellation reached this actor. See
    /// that method's doc comment for the full reasoning: unconditionally
    /// retracting exactly `fetch.token`'s own applied mutation from both
    /// cache layers (a no-op if nothing landed under it, or if a newer
    /// token has since superseded it) is required to uphold "the last
    /// waiter leaving must leave no partial cache entry" regardless of
    /// how far the revalidation's own network round trip had already
    /// progressed by the time this cancellation arrived.
    func cancelRevalidationWaiter(
        _ slot: RevalidationSlot,
        fetchID: UUID,
        waiterID: UUID
    ) async {
        guard var fetch = inFlightRevalidation[slot], fetch.id == fetchID else { return }
        guard let continuation = fetch.waiters.removeValue(forKey: waiterID) else {
            setInFlightRevalidation(fetch, for: slot)
            return
        }
        guard fetch.waiters.isEmpty else {
            setInFlightRevalidation(fetch, for: slot)
            continuation.resume(returning: .failure(CancellationError()))
            return
        }
        clearInFlightRevalidation(for: slot)
        retireIfCurrent(fetch.token, for: slot.cacheKey)
        // See ``AssetCacheService+Coalescing.swift``'s
        // ``cancelWaiter(_:fetchID:waiterID:)`` for why this must be
        // recorded synchronously, before either `await` below.
        markGenerationRetiring(fetch.token, for: slot.cacheKey)
        fetch.task.cancel()
        // Phase 1 (durable disk `.retiring` commit) is awaited to
        // completion before this exact waiter's own continuation is
        // resumed — see ``cancelWaiter(_:fetchID:waiterID:)``'s own
        // updated doc comment for the full reasoning this mirrors.
        // Only phase 2 (best-effort physical cleanup + final
        // `.tombstone` commit) is deferred to a detached `Task`.
        //
        // If phase 1 cannot be durably confirmed, this waiter must
        // never be told plain cancellation regardless -- durable disk
        // state may still say `.content` -- so it is instead resumed
        // with the typed failure directly.
        do {
            try await beginDurableRetractionIfApplied(slot.cacheKey, token: fetch.token)
            continuation.resume(returning: .failure(CancellationError()))
        } catch {
            continuation.resume(returning: .failure(error))
        }
        Task {
            await self.completeDurableRetractionIfApplied(slot.cacheKey, token: fetch.token)
        }
    }
}
