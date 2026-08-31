import Foundation

/// Completion (`completeRevalidation`) and the transport/mutation
/// pipeline (`performRevalidation`) a coalesced revalidation ultimately
/// runs — split out of `AssetCacheService+RevalidationCoalescing.swift`
/// purely to keep that file within this package's `file_length`
/// convention; still part of the single `AssetCacheService` actor's
/// isolated state.
extension AssetCacheService {
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
