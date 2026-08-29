import Foundation

/// Actor-isolated orchestration for resolving an ``AssetKey`` to validated
/// image bytes, backed by an in-memory cache, an on-disk cache, and a
/// network transport.
///
/// Responsibilities beyond the individual layers:
/// - Walks ``AssetLocator``'s candidate list, advancing to the next
///   candidate only on an exact 404 (``AssetHTTPResult/notFound``); every
///   other failure (transport, redirect, unexpected status, content
///   validation) is terminal for the whole request.
/// - Coalesces concurrent requests for the same resolved cache key onto a
///   single in-flight fetch. A waiter that cancels only decrements its own
///   share of that work; the underlying fetch is cancelled only once the
///   last waiter has left, and a cancelled fetch never publishes a partial
///   cache entry.
/// - Revalidates conditionally (`ETag`/`Last-Modified`) against the exact
///   URL a cached payload came from; a 304 is only ever treated as success
///   when paired with a currently valid cached payload.
actor AssetCacheService {
    private let memoryCache: AssetMemoryCache
    private let diskCache: AssetDiskCache
    private let transport: any AssetTransport
    private let digest: any LocalizedDigestLookup
    private let limits: AssetCacheLimits
    private var inFlight: [AssetCacheKey: InFlightFetch] = [:]

    /// The most recent disk-cache persistence failure from ``publish``, if
    /// any, retained so a best-effort (non-fatal) disk write failure is
    /// still auditable rather than silently swallowed — a resolved asset
    /// remains usable in-memory for the current process even when the
    /// on-disk cache could not be written (e.g. an unwritable or full
    /// cache directory), so this is deliberately not thrown back to the
    /// caller that just successfully resolved the asset.
    private(set) var lastDiskPersistenceFailure: AssetError?

    init(
        memoryCache: AssetMemoryCache,
        diskCache: AssetDiskCache,
        transport: any AssetTransport = URLSessionAssetTransport(),
        digest: any LocalizedDigestLookup = BundledLocalizedDigestProvider.shared,
        limits: AssetCacheLimits = .production
    ) {
        self.memoryCache = memoryCache
        self.diskCache = diskCache
        self.transport = transport
        self.digest = digest
        self.limits = limits
    }

    /// Resolves `key` to a validated cached asset, serving from memory or
    /// disk when a valid entry already exists and otherwise performing (or
    /// joining an already in-flight) network fetch.
    func asset(for key: AssetKey) async throws -> CachedAsset {
        let candidates = AssetLocator.candidates(for: key, digest: digest)
        guard !candidates.isEmpty else { throw AssetError.candidatesExhausted }
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)

        if let cached = await memoryCache.get(cacheKey) {
            return cached
        }
        if let cached = await diskCache.get(cacheKey) {
            await memoryCache.set(cacheKey, asset: cached)
            return cached
        }
        return try await coalescedFetch(key: key, cacheKey: cacheKey, candidates: candidates)
    }

    /// Conditionally revalidates an already-cached entry for `key` against
    /// the exact URL its payload came from. Requires a currently valid
    /// cached entry (memory or disk) to condition against; if none exists,
    /// throws ``AssetError/staleConditionalResponse`` immediately without
    /// making any network call, since there is nothing to pair a 304 with.
    ///
    /// Also requires the cached entry to actually carry a validator
    /// (`ETag` or `Last-Modified`): a 304 is only meaningful in response to
    /// a genuinely conditional request, so without either validator this
    /// throws the same typed error immediately rather than sending an
    /// unconditional request that a non-conforming server could still
    /// answer with a 304 we would otherwise wrongly accept as "unchanged".
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
        guard existing.metadata.etag != nil || existing.metadata.lastModified != nil else {
            throw AssetError.staleConditionalResponse
        }

        let request = AssetHTTPRequest(
            url: url,
            ifNoneMatch: existing.metadata.etag,
            ifModifiedSince: existing.metadata.etag == nil ? existing.metadata.lastModified : nil
        )
        let result = try await transport.fetch(request, limits: limits)
        switch result {
        case .notModified:
            var refreshed = existing
            refreshed.metadata.lastAccessedAt = Date()
            await publish(cacheKey, asset: refreshed)
            return refreshed
        case .notFound:
            // The previously cached resource no longer exists at its exact
            // resolved URL. This is not "no change"; treat it the same as
            // any other terminal transport outcome for a revalidation.
            throw AssetError.candidatesExhausted
        case let .success(response):
            return try await assembleRevalidatedAsset(
                key: key,
                cacheKey: cacheKey,
                url: url,
                existing: existing,
                response: response
            )
        }
    }

    /// Validates a fresh (non-304) revalidation response, assembles the
    /// replacement cache entry (preserving the original `insertedAt`), and
    /// publishes it.
    private func assembleRevalidatedAsset(
        key: AssetKey,
        cacheKey: AssetCacheKey,
        url: URL,
        existing: CachedAsset,
        response: AssetHTTPResponse
    ) async throws -> CachedAsset {
        let validated = try AssetImageValidator.validate(
            data: response.body,
            declaredContentType: response.contentType,
            expectedFormat: key.expectedFormat,
            limits: limits
        )
        try Task.checkCancellation()
        let asset = CachedAsset(
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
        await publish(cacheKey, asset: asset)
        return asset
    }

    /// Evicts every entry from both cache layers. Exposed for tests and for
    /// an explicit user-initiated "clear cache" action; never called
    /// automatically.
    func evictAll() async {
        await memoryCache.removeAll()
        await diskCache.removeAll()
    }

    // MARK: - Coalesced network fetch

    /// Tracks a single shared in-flight fetch and how many callers are
    /// still waiting on it. Uses its own lock (rather than actor
    /// isolation) so a waiter's cancellation handler — which Swift may run
    /// synchronously on an arbitrary executor — can adjust the waiter count
    /// without needing to hop back onto the ``AssetCacheService`` actor.
    private final class InFlightFetch: @unchecked Sendable {
        var task: Task<CachedAsset, Error>!
        private let lock = NSLock()
        private var waiterCount = 1

        func addWaiter() {
            lock.lock()
            waiterCount += 1
            lock.unlock()
        }

        /// Returns `true` when the caller removing itself was the last
        /// remaining waiter, meaning the underlying fetch should now be
        /// cancelled.
        func removeWaiter() -> Bool {
            lock.lock()
            waiterCount -= 1
            let isLast = waiterCount <= 0
            lock.unlock()
            return isLast
        }
    }

    private func coalescedFetch(
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate]
    ) async throws -> CachedAsset {
        let fetch: InFlightFetch
        if let existing = inFlight[cacheKey] {
            existing.addWaiter()
            fetch = existing
        } else {
            let newFetch = InFlightFetch()
            inFlight[cacheKey] = newFetch
            newFetch.task = Task { [weak self] in
                guard let self else { throw CancellationError() }
                do {
                    let result = try await fetchAndValidate(
                        key: key,
                        cacheKey: cacheKey,
                        candidates: candidates
                    )
                    await clearInFlight(cacheKey, matching: newFetch)
                    return result
                } catch {
                    await clearInFlight(cacheKey, matching: newFetch)
                    throw error
                }
            }
            fetch = newFetch
        }

        return try await withTaskCancellationHandler {
            try await fetch.task.value
        } onCancel: {
            if fetch.removeWaiter() {
                fetch.task.cancel()
            }
        }
    }

    private func clearInFlight(_ key: AssetCacheKey, matching fetch: InFlightFetch) {
        if inFlight[key] === fetch {
            inFlight[key] = nil
        }
    }

    /// Walks `candidates` in order against the network, advancing only on
    /// an exact 404, validating and persisting the first successful
    /// response. Re-checks cancellation immediately before publishing so a
    /// last-waiter cancellation racing with a just-completed network read
    /// never results in a published entry.
    private func fetchAndValidate(
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate]
    ) async throws -> CachedAsset {
        for candidate in candidates {
            try Task.checkCancellation()
            let url = candidate.url(base: key.source)
            let result = try await transport.fetch(AssetHTTPRequest(url: url), limits: limits)
            switch result {
            case .notFound:
                continue
            case .notModified:
                // An unconditional request never carries `If-None-Match` or
                // `If-Modified-Since`, so a 304 here indicates a
                // non-conforming server; there is no cached payload to pair
                // it with.
                throw AssetError.staleConditionalResponse
            case let .success(response):
                let validated = try AssetImageValidator.validate(
                    data: response.body,
                    declaredContentType: response.contentType,
                    expectedFormat: candidate.format,
                    limits: limits
                )
                try Task.checkCancellation()
                let asset = CachedAsset(
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
                        insertedAt: Date(),
                        lastAccessedAt: Date()
                    )
                )
                try Task.checkCancellation()
                await publish(cacheKey, asset: asset)
                return asset
            }
        }
        throw AssetError.candidatesExhausted
    }

    /// Publishes a resolved asset into both cache layers. The disk write
    /// is deliberately best-effort (an in-memory-only asset is still
    /// usable for the remainder of the process), but that decision is
    /// centralized here in an explicit `do`/`catch` — rather than a bare
    /// `try?` — so a persistence failure is captured in
    /// ``lastDiskPersistenceFailure`` for auditing/instrumentation instead
    /// of vanishing silently.
    private func publish(_ cacheKey: AssetCacheKey, asset: CachedAsset) async {
        await memoryCache.set(cacheKey, asset: asset)
        do {
            try await diskCache.set(cacheKey, payload: asset.payload, metadata: asset.metadata)
            lastDiskPersistenceFailure = nil
        } catch let error as AssetError {
            lastDiskPersistenceFailure = error
        } catch {
            lastDiskPersistenceFailure = .cachePersistenceFailed(String(describing: error))
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        AssetPayloadHasher.sha256Hex(data)
    }
}
