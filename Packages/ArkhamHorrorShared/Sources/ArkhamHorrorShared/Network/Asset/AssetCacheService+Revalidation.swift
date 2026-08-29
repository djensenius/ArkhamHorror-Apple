import Foundation

/// Conditional-revalidation subsystem for ``AssetCacheService``: re-checking
/// an on-disk hit against the current validation contract, and the
/// generation-gated ETag/Last-Modified revalidation path used when a
/// caller explicitly asks to revalidate an already-cached entry. Split
/// out of `AssetCacheService.swift` purely to keep each file within this
/// package's file/type-length conventions; still part of the single
/// `AssetCacheService` actor's isolated state.
extension AssetCacheService {
    /// Re-validates an on-disk cache hit against the *current* validation
    /// contract before ever trusting it as an already-resolved asset.
    ///
    /// ``AssetDiskCache/get(_:)`` already re-verifies the payload's byte
    /// count and SHA-256 hash against its own metadata (so the bytes are
    /// exactly what was written), but that alone does not prove the
    /// payload is still a genuinely valid, fully decodable image under
    /// *this process's* current limits: limits can tighten between
    /// launches, and a previously-published entry could in principle
    /// predate a validation fix. This re-runs the full
    /// format/magic-byte/dimension validation, cross-checks the freshly
    /// parsed dimensions against what metadata claims, and performs a full
    /// platform decode — never trusting metadata's `width`/`height` alone
    /// to stand in for a real decode.
    ///
    /// Returns `nil` (having already quarantined the disk entry) on any
    /// genuine mismatch or validation/decode failure. A `CancellationError`
    /// is rethrown instead of quarantining: it means the caller stopped
    /// caring, not that the entry is invalid.
    ///
    /// The persisted `resolvedURLString` is untrusted: a disk hit is only
    /// accepted when it exactly matches one of `key`'s own current
    /// candidates (never whatever URL happens to be recorded), which also
    /// recovers the exact ``AssetFormat`` that candidate resolved to.
    func revalidateDiskHit(
        _ cached: CachedAsset,
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate]
    ) async throws -> CachedAsset? {
        guard let candidate = candidates.first(where: {
            $0.url(base: key.source).absoluteString == cached.metadata.resolvedURLString
        }) else {
            await invalidate(cacheKey)
            return nil
        }
        do {
            let validated = try AssetImageValidator.validate(
                data: cached.payload,
                declaredContentType: cached.metadata.contentType,
                expectedFormat: candidate.format,
                limits: limits
            )
            guard
                validated.width == cached.metadata.width,
                validated.height == cached.metadata.height
            else {
                throw AssetError.malformedImageData
            }
            let decoded = try await decodeImageOffActor(cached.payload)
            guard decoded.width == validated.width, decoded.height == validated.height else {
                throw AssetError.malformedImageData
            }
            return cached
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await invalidate(cacheKey)
            return nil
        }
    }

    /// Conditionally revalidates an already-cached entry for `key` against
    /// the exact URL its payload came from. Requires a currently valid
    /// cached entry (memory or disk) to condition against; if none exists,
    /// throws ``AssetError/staleConditionalResponse`` immediately without
    /// making any network call, since there is nothing to pair a 304 with.
    ///
    /// The persisted URL is also required to exactly match one of `key`'s
    /// own current resolved candidates (never trusted as-is), so tampered
    /// or corrupted on-disk metadata cannot redirect a revalidation request
    /// to an unexpected host or path.
    ///
    /// Also requires the cached entry to actually carry a validator
    /// (`ETag` or `Last-Modified`): a 304 is only meaningful in response to
    /// a genuinely conditional request, so without either validator this
    /// throws the same typed error immediately rather than sending an
    /// unconditional request that a non-conforming server could still
    /// answer with a 304 we would otherwise wrongly accept as "unchanged".
    ///
    /// Concurrent revalidations for the same cache key, URL, and validator
    /// snapshot (`ETag`/`Last-Modified`) are coalesced onto a single
    /// network round trip exactly like ``asset(for:)``'s candidate-walk
    /// fetch (see ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:)``).
    /// A per-key generation counter additionally guards every terminal
    /// outcome so that a delayed completion can never resurrect or
    /// overwrite state a more authoritative (logically newer) revalidation
    /// already concluded while this one was still in flight.
    func revalidate(for key: AssetKey) async throws -> CachedAsset {
        let candidates = try resolvedCandidates(for: key)
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)

        if let existing = await memoryCache.get(cacheKey) {
            return try await revalidateExisting(
                existing,
                key: key,
                cacheKey: cacheKey,
                candidates: candidates
            )
        }
        guard let onDisk = await diskCache.get(cacheKey) else {
            throw AssetError.staleConditionalResponse
        }
        // A disk-loaded body is never trusted as the basis for a
        // conditional request until it has passed the exact same current
        // format/magic-byte/dimension/limits/decode validation as a disk
        // *hit* in ``asset(for:)`` (see
        // ``revalidateDiskHit(_:key:cacheKey:candidates:)``): without
        // this, a persisted wrong-format, oversized, undecodable, or
        // stale-limits body could be silently "touched" (its
        // `lastAccessedAt` refreshed) or re-cached in memory the moment
        // the server happens to answer with 304, never re-validated
        // against this process's current contract at all.
        guard let validated = try await revalidateDiskHit(
            onDisk,
            key: key,
            cacheKey: cacheKey,
            candidates: candidates
        ) else {
            // Already quarantined by `revalidateDiskHit`: there is no
            // longer any valid basis for a *conditional* request, so fall
            // through to an ordinary unconditional fetch exactly as if
            // this had been a clean cache miss, rather than throwing or
            // risking a 304 paired with content nobody has validated.
            return try await coalescedFetch(key: key, cacheKey: cacheKey, candidates: candidates)
        }
        await memoryCache.set(cacheKey, asset: validated)
        return try await revalidateExisting(
            validated,
            key: key,
            cacheKey: cacheKey,
            candidates: candidates
        )
    }

    /// Validates `existing` (already confirmed current/valid by the
    /// caller) against `key`'s own resolved candidates and issues the
    /// actual conditional revalidation. Split out of ``revalidate(for:)``
    /// purely so that function can share this exact tail between its
    /// memory-hit and validated-disk-hit branches.
    private func revalidateExisting(
        _ existing: CachedAsset,
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate]
    ) async throws -> CachedAsset {
        guard let url = URL(string: existing.metadata.resolvedURLString) else {
            throw AssetError.staleConditionalResponse
        }
        // The persisted `resolvedURLString` is untrusted input (on-disk
        // metadata could be corrupted or tampered while still decoding and
        // passing the hash/size checks in `AssetDiskCache.get`): only ever
        // issue a revalidation request against a URL that exactly matches
        // one of this key's own current candidates, never whatever URL
        // happens to be recorded, so tampered metadata cannot redirect a
        // request to an unexpected host or path. Looking up the matching
        // candidate itself (rather than only checking membership in a set
        // of URL strings) is also what recovers the exact ``AssetFormat``
        // that candidate resolved to: candidates for the same key are not
        // all guaranteed to share one format, so `key.expectedFormat`
        // alone is not a safe stand-in for validating a fresh revalidation
        // response — see ``revalidateDiskHit(_:key:cacheKey:candidates:)``,
        // which recovers it identically for the disk-hit re-validation
        // path.
        guard
            let matchedCandidate = candidates.first(where: {
                $0.url(base: key.source).absoluteString == existing.metadata.resolvedURLString
            })
        else {
            throw AssetError.staleConditionalResponse
        }
        guard existing.metadata.etag != nil || existing.metadata.lastModified != nil else {
            throw AssetError.staleConditionalResponse
        }

        return try await coalescedRevalidation(
            cacheKey: cacheKey,
            url: url,
            expectedFormat: matchedCandidate.format,
            existing: existing
        )
    }

    /// Returns the ID of the in-flight revalidation `slot` should join:
    /// either an already-registered fetch, or a freshly-started one this
    /// call registers itself. Split out of
    /// ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:)`` purely to
    /// keep that function's body within this package's
    /// `function_body_length` limit.
    func resolveRevalidationFetchID(
        cacheKey: AssetCacheKey,
        url: URL,
        expectedFormat: AssetFormat,
        existing: CachedAsset,
        slot: RevalidationSlot
    ) -> UUID {
        if let current = inFlightRevalidation[slot] {
            return current.id
        }
        let startEpoch = currentEpoch(for: cacheKey)
        let revalidationRequest = RevalidationRequest(
            cacheKey: cacheKey,
            url: url,
            expectedFormat: expectedFormat,
            existing: existing,
            etag: slot.etag,
            lastModified: slot.lastModified,
            startEpoch: startEpoch
        )
        let newTask = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await performRevalidation(revalidationRequest)
        }
        let newFetch = RevalidationFetch(task: newTask)
        inFlightRevalidation[slot] = newFetch
        let fetchID = newFetch.id
        Task { [weak self] in
            let result = await newTask.result
            await self?.completeRevalidation(slot, fetchID: fetchID, result: result)
        }
        return fetchID
    }
}
