import Foundation

/// Coalescing, cancellation, and completion for concurrent
/// ``AssetCacheService`` revalidation requests, plus the transport
/// pipeline (`performRevalidation`) and disk/memory assembly
/// (`assembleRevalidatedAsset`) a coalesced revalidation ultimately runs.
/// Split out of `AssetCacheService+Revalidation.swift` purely to keep
/// each file within this package's file/type-length conventions; still
/// part of the single `AssetCacheService` actor's isolated state.
extension AssetCacheService {
    /// Test-only observability accessor: mirrors
    /// ``inFlightWaiterCount(for:)`` for coalesced revalidations --
    /// summed across every currently in-flight revalidation slot for
    /// `cacheKey` (there is normally at most one at a time in the
    /// scenarios that need this). Lets tests synchronize on real
    /// actor-isolated state instead of a `Task.sleep` guess.
    func inFlightRevalidationWaiterCount(forCacheKey cacheKey: AssetCacheKey) -> Int {
        inFlightRevalidation
            .filter { $0.key.cacheKey == cacheKey }
            .reduce(0) { $0 + $1.value.waiters.count }
    }

    /// `preIssuedAuthority` is a durable clear epoch the caller already read
    /// (via ``currentDurableClearEpoch()``) at its own synchronous
    /// decision point, immediately before calling this — every caller
    /// (the memory-hit and validated-disk-hit branches of
    /// ``revalidate(for:)``, and ``asset(for:)``'s disk-hit branch
    /// calling this directly) now reads its own epoch immediately at
    /// that decision point, rather than only some of them doing so and
    /// this call reading one later itself for the rest. Never a full
    /// pre-issued ``CacheToken``: threading a token (rather than a bare
    /// epoch value) through here would force every caller to call
    /// ``issueToken(for:)`` unconditionally before knowing whether this
    /// operation will join already in-flight work or create fresh work,
    /// clobbering whatever token the in-flight fetch it might join is
    /// relying on — see
    /// ``revalidateExisting(_:key:cacheKey:candidates:preIssuedAuthority:)``'s
    /// doc comment. Threaded straight through to
    /// ``resolveRevalidationFetchID(expectedFormat:existing:slot:preIssuedAuthority:)``,
    /// which mints the actual authoritative token itself, and only on
    /// its own "create fresh work" branch, so a fresh network round trip
    /// started here never mints unrelated, always-immediately-
    /// authoritative new authority from bytes that epoch has already
    /// validated.
    func coalescedRevalidation(
        cacheKey: AssetCacheKey,
        url: URL,
        expectedFormat: AssetFormat,
        existing: CachedAsset,
        preIssuedAuthority: PreIssuedAuthority?
    ) async throws -> CachedAsset {
        let etag = existing.metadata.etag
        let lastModified = existing.metadata.etag == nil ? existing.metadata.lastModified : nil
        let slot = RevalidationSlot(
            cacheKey: cacheKey,
            url: url,
            etag: etag,
            lastModified: lastModified
        )
        let waiterID = UUID()
        let resolved = resolveRevalidationFetchID(
            expectedFormat: expectedFormat,
            existing: existing,
            slot: slot,
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
            // See the identical `Task.isCancelled` override in
            // `coalescedFetch` for why this check is race-free even though
            // the resumed `result` value alone would not be.
            if Task.isCancelled {
                throw CancellationError()
            }
            let delivered = try result.get()
            // Final actor-isolated authority/liveness re-check,
            // immediately before this specific waiter returns a
            // success-shaped value to its own caller: significant
            // suspension can have elapsed between the moment the shared
            // revalidation's own `publish`/`touch` call landed
            // successfully under `token` and the moment this exact
            // waiter's continuation actually resumes (the completion
            // watcher iterating every waiter, this waiter's own
            // scheduling, or simply another waiter's continuation being
            // resumed first) — during which a more-recently-issued
            // operation for this exact key, or a cache-wide
            // `evictAll()`, may already have superseded `token`. Without
            // this, such a waiter could still return a value shaped as
            // current/successful even though this actor's own
            // bookkeeping no longer considers it so, entirely
            // independent of whether the underlying cache mutation
            // itself remains correct (``publish``/``touch`` already
            // retract their own mutation the instant *they* detect this
            // same staleness — this closes the analogous gap for what
            // this waiter hands back to its caller).
            guard await isAuthoritative(token, for: cacheKey) else {
                throw AssetError.staleOperation
            }
            return delivered
        } onCancel: {
            Task {
                await self.cancelRevalidationWaiter(slot, fetchID: fetchID, waiterID: waiterID)
            }
        }
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
            fetch.task.cancel()
            await memoryCache.removeIfApplied(slot.cacheKey, token: fetch.token)
            await diskCache.removeIfApplied(slot.cacheKey, token: fetch.token)
        } else {
            setInFlightRevalidation(fetch, for: slot)
        }
    }

    func completeRevalidation(
        _ slot: RevalidationSlot,
        fetchID: UUID,
        result: Result<CachedAsset, Error>
    ) {
        guard let fetch = inFlightRevalidation[slot], fetch.id == fetchID else { return }
        clearInFlightRevalidation(for: slot)
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
            // ``AssetError/staleConditionalResponse``'s distinct meaning,
            // used elsewhere in this subsystem for "no cached payload
            // exists to pair a 304 with" and similar protocol-level
            // preconditions). Using the same error for both would make it
            // impossible for a caller/test to tell a normal staleness
            // race apart from a genuine protocol violation.
            guard await isAuthoritative(token, for: cacheKey) else {
                throw AssetError.staleOperation
            }
            var refreshed = request.existing
            refreshed.metadata.accessSequence = AssetAccessSequence(0)
            // Re-stamped with *this* revalidation's own token's durable
            // epoch rather than left carrying whatever epoch
            // `request.existing` happened to be stamped with: a memory
            // hit's own entry can be arbitrarily old, and blindly forward
            // -carrying its epoch here would let a memory entry that
            // ``memoryEntryStillCurrent(_:)`` would otherwise correctly
            // reject on a subsequent hit instead keep re-validating this
            // exact same stale epoch value forever, immune to that check
            // entirely.
            refreshed.durableClearEpoch = token.durableClearEpoch
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
            // published (or be about to publish) fresh content for it.
            guard await invalidate(cacheKey, token: token) == .applied else {
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

    /// Validates a fresh (non-304) revalidation response and assembles the
    /// replacement cache entry (preserving the original `insertedAt`),
    /// without publishing it — the caller (``performRevalidation``) alone
    /// decides whether this result is still eligible to publish, after
    /// re-checking the generation it was started under.
    ///
    /// Validates against `expectedFormat` — the exact resolved candidate's
    /// format recovered by ``revalidate(for:)`` — rather than
    /// `key.expectedFormat`: candidates for the same key are not all
    /// guaranteed to share one format, so using the key's own default
    /// alone could validate against the wrong magic bytes/MIME
    /// expectations if the candidate chain ever includes mixed formats
    /// (see ``revalidateDiskHit(_:key:cacheKey:candidates:)``, which
    /// recovers it identically for the disk-hit re-validation path).
    func assembleRevalidatedAsset(
        request: RevalidationRequest,
        response: AssetHTTPResponse
    ) async throws -> CachedAsset {
        let validated = try AssetImageValidator.validate(
            data: response.body,
            declaredContentType: response.contentType,
            expectedFormat: request.expectedFormat,
            limits: limits
        )
        try Task.checkCancellation()
        // A full platform decode, not just the pure metadata/dimension
        // parse above, is required before this payload is ever eligible
        // for cache publication: `validate` deliberately only parses
        // enough of a format's structure to safely read declared
        // dimensions without a full decode, so it alone cannot detect an
        // otherwise well-formed header describing a coded image that is
        // truncated, missing, or corrupt (for example a PNG with only an
        // `IHDR` chunk, a JPEG `SOF` with no scan data/EOI, or an AVIF
        // `meta` shell with no backing `mdat`). Cross-checking the
        // decoded image's own dimensions against the validator's parsed
        // dimensions also catches a mismatched/ambiguous primary item.
        let decoded = try await decodeImageOffActor(response.body)
        guard decoded.width == validated.width, decoded.height == validated.height else {
            throw AssetError.malformedImageData
        }
        try Task.checkCancellation()
        return CachedAsset(
            payload: response.body,
            metadata: AssetCacheMetadata(
                cacheKeyHex: request.cacheKey.digestHex,
                contentType: response.contentType ?? validated.format.mimeType,
                encodedByteCount: response.body.count,
                width: validated.width,
                height: validated.height,
                payloadSHA256Hex: Self.sha256Hex(response.body),
                etag: response.etag,
                lastModified: response.lastModified,
                resolvedURLString: request.url.absoluteString,
                insertedAt: request.existing.metadata.insertedAt,
                accessSequence: AssetAccessSequence(0)
            ),
            durableClearEpoch: request.token.durableClearEpoch
        )
    }
}
