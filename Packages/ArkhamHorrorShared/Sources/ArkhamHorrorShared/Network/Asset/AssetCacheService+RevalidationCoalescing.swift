import Foundation

/// Coalescing, cancellation, and completion for concurrent
/// ``AssetCacheService`` revalidation requests, plus the transport
/// pipeline (`performRevalidation`) and disk/memory assembly
/// (`assembleRevalidatedAsset`) a coalesced revalidation ultimately runs.
/// Split out of `AssetCacheService+Revalidation.swift` purely to keep
/// each file within this package's file/type-length conventions; still
/// part of the single `AssetCacheService` actor's isolated state.
extension AssetCacheService {
    func coalescedRevalidation(
        cacheKey: AssetCacheKey,
        url: URL,
        expectedFormat: AssetFormat,
        existing: CachedAsset
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
        let fetchID = resolveRevalidationFetchID(
            cacheKey: cacheKey,
            url: url,
            expectedFormat: expectedFormat,
            existing: existing,
            slot: slot
        )

        return try await withTaskCancellationHandler {
            let result = await withCheckedContinuation { (continuation: AssetContinuation) in
                // See ``coalescedFetch(key:cacheKey:candidates:)`` for why
                // this synchronous registration, performed directly from
                // actor-isolated code, is race-free without extra locking.
                if inFlightRevalidation[slot]?.id == fetchID {
                    var fetch = inFlightRevalidation[slot]
                    fetch?.waiters[waiterID] = continuation
                    inFlightRevalidation[slot] = fetch
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
            return try result.get()
        } onCancel: {
            Task {
                await self.cancelRevalidationWaiter(slot, fetchID: fetchID, waiterID: waiterID)
            }
        }
    }

    func cancelRevalidationWaiter(
        _ slot: RevalidationSlot,
        fetchID: UUID,
        waiterID: UUID
    ) {
        guard var fetch = inFlightRevalidation[slot], fetch.id == fetchID else { return }
        if let continuation = fetch.waiters.removeValue(forKey: waiterID) {
            continuation.resume(returning: .failure(CancellationError()))
        }
        if fetch.waiters.isEmpty {
            inFlightRevalidation[slot] = nil
            fetch.task.cancel()
        } else {
            inFlightRevalidation[slot] = fetch
        }
    }

    func completeRevalidation(
        _ slot: RevalidationSlot,
        fetchID: UUID,
        result: Result<CachedAsset, Error>
    ) {
        guard let fetch = inFlightRevalidation[slot], fetch.id == fetchID else { return }
        inFlightRevalidation[slot] = nil
        for (_, continuation) in fetch.waiters {
            continuation.resume(returning: result)
        }
    }

    /// Performs the actual conditional network round trip and every
    /// cache-mutating outcome, gated by `request.startEpoch` — a 404, a
    /// 304, and a fresh 200 are all checked identically (see
    /// `AssetCacheService+Epoch.swift`'s doc comment for why an
    /// unconditionally-authoritative 404 is itself a hazard: a *stale*
    /// 404, completing after a newer request already published fresh
    /// content for this exact key, must not evict it). Each branch
    /// re-checks ``AssetCacheService/isCurrentEpoch(_:for:)`` immediately
    /// before its own mutation and bumps this key's epoch immediately
    /// after — never touching or reinserting captured bytes/metadata if a
    /// more authoritative completion (this same check, from a different
    /// overlapping revalidation, fetch, or `evictAll()`) already moved the
    /// epoch forward while this round trip — including the network wait
    /// *and* the validate/decode work for a 200 — was in progress.
    func performRevalidation(_ request: RevalidationRequest) async throws -> CachedAsset {
        let cacheKey = request.cacheKey
        let httpRequest = AssetHTTPRequest(
            url: request.url,
            ifNoneMatch: request.etag,
            ifModifiedSince: request.lastModified
        )
        let result = try await transport.fetch(httpRequest, limits: limits)
        switch result {
        case .notModified:
            guard isCurrentEpoch(request.startEpoch, for: cacheKey) else {
                throw AssetError.staleConditionalResponse
            }
            var refreshed = request.existing
            refreshed.metadata.accessSequence = AssetAccessSequence(0)
            bumpKeyEpoch(cacheKey)
            await touch(cacheKey, asset: refreshed)
            return refreshed
        case .notFound:
            // The previously cached resource no longer exists at its exact
            // resolved URL. This is not "no change": the stale entry must
            // be evicted from both cache layers so subsequent `asset(for:)`
            // calls do not keep serving content the server has definitively
            // removed. Still epoch-gated exactly like the other two
            // branches: a *stale* 404 (a slow response to an old request,
            // completing after a newer request already published fresh
            // content) must not evict what that newer completion just
            // published.
            guard isCurrentEpoch(request.startEpoch, for: cacheKey) else {
                throw AssetError.staleConditionalResponse
            }
            bumpKeyEpoch(cacheKey)
            await invalidate(cacheKey)
            throw AssetError.candidatesExhausted
        case let .success(response):
            let asset = try await assembleRevalidatedAsset(
                cacheKey: cacheKey,
                url: request.url,
                expectedFormat: request.expectedFormat,
                existing: request.existing,
                response: response
            )
            guard isCurrentEpoch(request.startEpoch, for: cacheKey) else {
                // A more authoritative completion (another fetch,
                // revalidation, or `evictAll()`) concluded while this
                // response was being received/validated/decoded;
                // publishing this now-stale result would resurrect
                // content that was already superseded or evicted.
                throw AssetError.staleConditionalResponse
            }
            bumpKeyEpoch(cacheKey)
            await publish(cacheKey, asset: asset)
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
        cacheKey: AssetCacheKey,
        url: URL,
        expectedFormat: AssetFormat,
        existing: CachedAsset,
        response: AssetHTTPResponse
    ) async throws -> CachedAsset {
        let validated = try AssetImageValidator.validate(
            data: response.body,
            declaredContentType: response.contentType,
            expectedFormat: expectedFormat,
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
                cacheKeyHex: cacheKey.digestHex,
                contentType: response.contentType ?? validated.format.mimeType,
                encodedByteCount: response.body.count,
                width: validated.width,
                height: validated.height,
                payloadSHA256Hex: Self.sha256Hex(response.body),
                etag: response.etag,
                lastModified: response.lastModified,
                resolvedURLString: url.absoluteString,
                insertedAt: existing.metadata.insertedAt,
                accessSequence: AssetAccessSequence(0)
            )
        )
    }
}
