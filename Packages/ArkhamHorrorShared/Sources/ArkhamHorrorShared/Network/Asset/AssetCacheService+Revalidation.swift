import Foundation

/// Conditional-revalidation subsystem for ``AssetCacheService``: re-checking
/// an on-disk hit against the current validation contract, and the
/// generation-gated ETag/Last-Modified revalidation path used when a
/// caller explicitly asks to revalidate an already-cached entry. Split
/// into its own file (from the core fetch/coalescing logic in
/// `AssetCacheService.swift`) purely to keep each file within this
/// package's file/type-length conventions; these members are still part
/// of the single `AssetCacheService` actor's isolated state.
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
    /// The persisted `resolvedURLString` is untrusted (as in
    /// ``revalidate(for:)``): a disk hit is only accepted when that URL
    /// still exactly matches one of `key`'s own current candidates, which
    /// also recovers the exact ``AssetFormat`` the candidate walk resolved
    /// (candidates for the same key are not all guaranteed to share one
    /// format, so `key.expectedFormat` alone is not a safe stand-in here).
    ///
    /// Returns `nil` (having already quarantined the disk entry) on any
    /// mismatch or failure, so the caller can treat this exactly like a
    /// cache miss.
    func revalidateDiskHit(
        _ cached: CachedAsset,
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate]
    ) async -> CachedAsset? {
        guard let candidate = candidates.first(where: {
            $0.url(base: key.source).absoluteString == cached.metadata.resolvedURLString
        }) else {
            await diskCache.remove(cacheKey)
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
            let decoded = try AssetImageDecoder.decode(cached.payload)
            guard decoded.width == validated.width, decoded.height == validated.height else {
                throw AssetError.malformedImageData
            }
            return cached
        } catch {
            await diskCache.remove(cacheKey)
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
        let candidates = AssetLocator.candidates(for: key, digest: digest)
        guard !candidates.isEmpty else { throw AssetError.candidatesExhausted }
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)

        var existing = await memoryCache.get(cacheKey)
        if existing == nil {
            existing = await diskCache.get(cacheKey)
        }
        guard let existing else {
            throw AssetError.staleConditionalResponse
        }
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
    private func resolveRevalidationFetchID(
        cacheKey: AssetCacheKey,
        url: URL,
        expectedFormat: AssetFormat,
        existing: CachedAsset,
        slot: RevalidationSlot
    ) -> UUID {
        if let current = inFlightRevalidation[slot] {
            return current.id
        }
        let startGeneration = revalidationGeneration[cacheKey, default: 0]
        let revalidationRequest = RevalidationRequest(
            cacheKey: cacheKey,
            url: url,
            expectedFormat: expectedFormat,
            existing: existing,
            etag: slot.etag,
            lastModified: slot.lastModified,
            startGeneration: startGeneration
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
    /// cache-mutating outcome, gated by `request.startGeneration`: a 404
    /// evicts and unconditionally bumps the generation (it is
    /// unambiguously authoritative — the resource is definitively gone); a
    /// 304 or fresh 200 first re-checks that `request.startGeneration` is
    /// still current immediately before mutating anything, throwing
    /// ``AssetError/staleConditionalResponse`` instead of touching or
    /// reinserting its own captured bytes/metadata if a more authoritative
    /// completion (this same check, from a different overlapping
    /// revalidation) already moved the generation forward while this
    /// round trip — including the network wait *and* the validate/decode
    /// work for a 200 — was in progress.
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
            guard isCurrentRevalidationGeneration(cacheKey, request.startGeneration) else {
                throw AssetError.staleConditionalResponse
            }
            var refreshed = request.existing
            refreshed.metadata.lastAccessedAt = Date()
            bumpRevalidationGeneration(cacheKey)
            await touch(cacheKey, asset: refreshed)
            return refreshed
        case .notFound:
            // The previously cached resource no longer exists at its exact
            // resolved URL. This is not "no change": the stale entry must
            // be evicted from both cache layers so subsequent `asset(for:)`
            // calls do not keep serving content the server has definitively
            // removed. Unconditionally authoritative, so this bumps the
            // generation regardless of `startGeneration`'s current value —
            // any older, still-in-flight sibling revalidation must be
            // unable to resurrect what this just evicted.
            bumpRevalidationGeneration(cacheKey)
            await memoryCache.remove(cacheKey)
            await diskCache.remove(cacheKey)
            throw AssetError.candidatesExhausted
        case let .success(response):
            let asset = try await assembleRevalidatedAsset(
                cacheKey: cacheKey,
                url: request.url,
                expectedFormat: request.expectedFormat,
                existing: request.existing,
                response: response
            )
            guard isCurrentRevalidationGeneration(cacheKey, request.startGeneration) else {
                // A more authoritative completion (typically a definitive
                // 404) concluded while this response was being
                // received/validated/decoded; publishing this now-stale
                // result would resurrect content that was just evicted.
                throw AssetError.staleConditionalResponse
            }
            bumpRevalidationGeneration(cacheKey)
            await publish(cacheKey, asset: asset)
            return asset
        }
    }

    func isCurrentRevalidationGeneration(_ key: AssetCacheKey, _ generation: Int) -> Bool {
        revalidationGeneration[key, default: 0] == generation
    }

    func bumpRevalidationGeneration(_ key: AssetCacheKey) {
        revalidationGeneration[key, default: 0] += 1
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
        let decoded = try AssetImageDecoder.decode(response.body)
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
                lastAccessedAt: Date()
            )
        )
    }
}
