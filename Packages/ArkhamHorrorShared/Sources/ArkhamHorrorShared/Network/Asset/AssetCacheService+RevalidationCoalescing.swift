import Foundation

/// Coalescing, cancellation, and completion for concurrent
/// ``AssetCacheService`` revalidation requests, plus the transport
/// pipeline (`performRevalidation`) and disk/memory assembly
/// (`assembleRevalidatedAsset`) a coalesced revalidation ultimately runs.
/// Split out of `AssetCacheService+Revalidation.swift` purely to keep
/// each file within this package's file/type-length conventions; still
/// part of the single `AssetCacheService` actor's isolated state.
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
            // ``finalizeRevalidationWaiterOutcome(_:waiter:token:currentEpoch:resultIsSuccess:)``
            // below, as the very last step before this waiter's outcome
            // is decided — see `finalizeFetchWaiterOutcome`'s doc
            // comment (`AssetCacheService+Coalescing.swift`) for why
            // folding the cancellation check, the authority re-check, and
            // this exact waiter's ledger acknowledgement into that single
            // synchronous actor method — rather than separate steps, as a
            // prior revision of this code had — is required.
            let currentEpoch = await currentDurableClearEpoch()
            let resultIsSuccess = if case .success = result {
                true
            } else {
                false
            }
            let outcome = finalizeRevalidationWaiterOutcome(
                slot,
                waiter: WaiterIdentity(fetchID: fetchID, waiterID: waiterID),
                token: token,
                currentEpoch: currentEpoch,
                resultIsSuccess: resultIsSuccess
            )
            switch outcome {
            case .cancelled:
                throw CancellationError()
            case .stale:
                throw AssetError.staleOperation
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
        await acquireIssuanceDecisionLock(for: cacheKey)
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
        if let continuation = fetch.waiters.removeValue(forKey: waiterID) {
            continuation.resume(returning: .failure(CancellationError()))
        }
        if fetch.waiters.isEmpty {
            clearInFlightRevalidation(for: slot)
            retireIfCurrent(fetch.token, for: slot.cacheKey)
            // See ``AssetCacheService+Coalescing.swift``'s
            // ``cancelWaiter(_:fetchID:waiterID:)`` for why this must be
            // recorded synchronously, before either `await` below.
            markGenerationRetiring(fetch.token, for: slot.cacheKey)
            fetch.task.cancel()
            await retractIfApplied(slot.cacheKey, token: fetch.token)
        } else {
            setInFlightRevalidation(fetch, for: slot)
        }
    }

    /// Called exactly once by the shared revalidation's own completion
    /// watcher. Mirrors ``completeFetch(_:fetchID:result:)`` exactly,
    /// including seeding ``pendingRevalidationAcknowledgement`` (keyed by
    /// `fetchID`) with this exact set of resumed waiters before any of
    /// them is actually resumed — see that method's own doc comment and
    /// `AssetCacheService+WaiterAcknowledgement.swift`'s type-level doc
    /// comment for the full reasoning.
    func completeRevalidation(
        _ slot: RevalidationSlot,
        fetchID: UUID,
        result: Result<CachedAsset, Error>
    ) {
        guard let fetch = inFlightRevalidation[slot], fetch.id == fetchID else { return }
        clearInFlightRevalidation(for: slot)
        pendingRevalidationAcknowledgement[fetchID] = PendingWaiterAcknowledgement(
            key: slot,
            token: fetch.token,
            pendingWaiterIDs: Set(fetch.waiters.keys)
        )
        testOnlyBeforeRevalidationResumesWaiters?()
        for (_, continuation) in fetch.waiters {
            continuation.resume(returning: result)
        }
    }

    /// Performs the actual conditional network round trip and every
    /// cache-mutating outcome, gated by `request.token` — a 404, a
    /// 304, and a fresh 200 are all checked identically (see
    /// `AssetCacheService+Epoch.swift`'s doc comment for why an
    /// unconditionally-authoritative 404 is itself a hazard: a *stale*
    /// 404, completing after a newer request already published fresh
    /// content for this exact key, must not evict it). Each branch
    /// re-checks ``AssetCacheService/isAuthoritative(_:for:)`` immediately
    /// before its own mutation — never touching or reinserting captured
    /// bytes/metadata if a more-recently-issued operation for this exact
    /// key (a different overlapping revalidation, a fetch, or
    /// `evictAll()`) has already been issued while this round trip —
    /// including the network wait *and* the validate/decode work for a
    /// 200 — was in progress. Unlike the old completion-ordered epoch
    /// design, there is no "bump on completion" step here: authority is
    /// fixed once, at issuance (see ``AssetCacheService/issueToken(for:)``),
    /// so an older-issued operation that happens to complete first can
    /// never win against a newer-issued one that is still in flight.
    func performRevalidation(_ request: RevalidationRequest) async throws -> CachedAsset {
        let cacheKey = request.cacheKey
        // `request.token` is guaranteed already stamped with the durable
        // clear epoch by the caller, at its own synchronous issuance
        // point (see `AssetCacheService+Revalidation.swift`'s
        // ``AssetCacheService/revalidate(for:)`` memory-hit/disk-hit
        // branches and ``AssetCacheService/diskHitIfTrusted(key:cacheKey:candidates:)``)
        // — never re-stamped here. Re-stamping at this later point, once
        // this function's `Task` has actually been scheduled, would read
        // whatever durable epoch happens to be current *at that later
        // moment* — which could already reflect a cross-instance/
        // cross-process clear that happened strictly *after* this
        // revalidation was logically issued — and silently "launder"
        // that clear as if it had already been accounted for when this
        // operation began, letting a 304 paired with pre-clear bytes
        // sail through the very authority checks below that exist to
        // prevent exactly that.
        let token = request.token
        let httpRequest = AssetHTTPRequest(
            url: request.url,
            ifNoneMatch: request.etag,
            ifModifiedSince: request.lastModified
        )
        let result = try await transport.fetch(httpRequest, limits: limits)
        switch result {
        case .notModified:
            // A lost-authority result here means this specific operation
            // was superseded by a more-recently-issued one racing it (a
            // newer fetch/revalidation, or `evictAll()`) — a staleness
            // race, never a claim that the *conditional-response
            // protocol itself* was violated (that is
            // ``AssetError/staleConditionalResponse``'s distinct
            // meaning, used elsewhere for "no cached payload exists to
            // pair a 304 with"). Using the same error for both would
            // make it impossible to tell a staleness race apart from a
            // genuine protocol violation.
            guard await isAuthoritative(token, for: cacheKey) else {
                throw AssetError.staleOperation
            }
            var updatedMetadata = request.existing.metadata
            updatedMetadata.accessSequence = AssetAccessSequence(0)
            // `writeGenerationAtPublication`/`writeGeneration` *are*
            // advanced here, to `token`'s own freshly issued ticket —
            // this 304 is itself a genuine, durable re-confirmation that
            // these exact bytes are still current, and
            // ``AssetDiskCache/touch(_:metadata:token:)`` (called below)
            // always durably commits `token`'s ticket as this key's new
            // disk *applied* ticket regardless of what this metadata
            // says; leaving this field frozen at the original publish's
            // ticket would silently drift it out of sync with that disk
            // counter after this exact call, permanently poisoning every
            // *subsequent* revalidation's own provenance check (see
            // ``AssetCacheMetadata/writeGenerationAtPublication``'s own
            // doc comment for the full "sequential 304" scenario this
            // closes). `clearEpochAtPublication`/`durableClearEpoch` are
            // deliberately left exactly as ``request.existing`` already
            // carries: the `isAuthoritative` re-check immediately above
            // already re-verified `token`'s own durable clear epoch
            // exactly matches the current one (and, transitively —
            // `beginRevalidationIssuance` having accepted this
            // operation's issuance at all already proved that epoch
            // matched `request.existing`'s own historical stamp too) —
            // so both are already guaranteed identical at this exact
            // point; restamping would write the same value, not a
            // different one. See
            // ``AssetCacheMetadata/clearEpochAtPublication``'s own doc
            // comment for why this field is never restamped as a matter
            // of principle regardless.
            guard let freshTicket = token.diskWriteGeneration else {
                throw AssetError.staleOperation
            }
            updatedMetadata.writeGenerationAtPublication = freshTicket
            // Built via ``CachedAsset/withUpdatedMetadata(_:writeGeneration:)``,
            // never by mutating a copy of `request.existing` in place: a
            // plain field mutation would leave `accountedByteCount` frozen
            // at whatever `updatedMetadata`'s *previous* serialized size
            // was, silently under- or over-billing this entry against
            // ``AssetMemoryCache``'s quota the instant
            // `writeGenerationAtPublication`'s own digit count changes
            // (e.g. a ticket advancing from `9` to `10`) — see that
            // method's own doc comment for the exact "quota accounting
            // cost stale after a metadata-only mutation" defect this
            // closes.
            let refreshed = request.existing.withUpdatedMetadata(
                updatedMetadata,
                writeGeneration: freshTicket
            )
            // See the identical final ``MutationOutcome`` re-check on the
            // `.success` branch below for why a `.stale` result here must
            // also surface as ``AssetError/staleOperation`` rather than
            // returning `refreshed` as if this 304 had actually landed.
            guard await touch(cacheKey, asset: refreshed, token: token) == .applied else {
                throw AssetError.staleOperation
            }
            return refreshed
        case .notFound:
            // The previously cached resource no longer exists at its exact
            // resolved URL. This is not "no change": the stale entry must
            // be evicted from both cache layers so subsequent `asset(for:)`
            // calls do not keep serving content the server has definitively
            // removed. Still authority-gated exactly like the other two
            // branches: a *stale* 404 (a slow response to an old request,
            // completing after a newer request already published fresh
            // content) must not evict what that newer completion just
            // published. See the `.notModified` case above for why this
            // is ``AssetError/staleOperation`` (a race), not
            // ``AssetError/staleConditionalResponse`` (a protocol
            // violation).
            guard await isAuthoritative(token, for: cacheKey) else {
                throw AssetError.staleOperation
            }
            // A `.stale` outcome here means a newer operation already
            // superseded this 404 before the invalidation itself could
            // land; reporting `candidatesExhausted` in that case would
            // wrongly tell this caller the asset is gone when a
            // more-authoritative concurrent operation may since have
            // published fresh content for it. A thrown error (a durable
            // disposition failure -- see ``invalidate(_:token:)``'s own
            // doc comment) propagates straight out rather than folding
            // into either error below: a definitive 404 must never
            // report success or advance the fallback chain until a
            // durable tombstone has actually landed.
            guard try await invalidate(cacheKey, token: token) == .applied else {
                throw AssetError.staleOperation
            }
            throw AssetError.candidatesExhausted
        case let .success(response):
            let asset = try await assembleRevalidatedAsset(
                request: request,
                response: response
            )
            guard await isAuthoritative(token, for: cacheKey) else {
                // A more-recently-issued operation (another fetch,
                // revalidation, or `evictAll()`) has already concluded
                // while this response was being received/validated/
                // decoded; publishing this now-stale result would
                // resurrect content that was already superseded or
                // evicted. See the `.notModified` case above for why this
                // is ``AssetError/staleOperation``, not
                // ``AssetError/staleConditionalResponse``.
                throw AssetError.staleOperation
            }
            guard await publish(cacheKey, asset: asset, token: token) == .applied else {
                throw AssetError.staleOperation
            }
            await testOnlyPauseAfterFetchPublishApplied?()
            return asset
        }
    }
}
