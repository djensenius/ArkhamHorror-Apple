import CoreGraphics
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
    /// Shorthand for the continuation type shared by both the coalesced
    /// network-fetch and coalesced-revalidation waiter dictionaries, kept
    /// as a single typealias (rather than repeating the full generic
    /// spelling at every use site) purely so those call sites stay under
    /// this package's line-length limit.
    typealias AssetContinuation = CheckedContinuation<Result<CachedAsset, Error>, Never>

    let memoryCache: AssetMemoryCache
    let diskCache: AssetDiskCache
    let transport: any AssetTransport
    let digest: any LocalizedDigestLookup
    let limits: AssetCacheLimits
    private var inFlight: [AssetCacheKey: InFlightFetch] = [:]

    /// Monotonically increases every time a revalidation for a given
    /// ``AssetCacheKey`` reaches ANY terminal, cache-mutating outcome (a
    /// definitive 404 eviction, a 304 metadata touch, or a fresh publish).
    /// A revalidation captures the generation current at its own start and
    /// re-checks it immediately before every mutation; a mismatch means a
    /// more authoritative (and logically newer) revalidation already
    /// concluded while this one's network round trip was in flight, so
    /// this one must not touch or reinsert its own (now stale) captured
    /// bytes/metadata — see ``performRevalidation(_:)``.
    var revalidationGeneration: [AssetCacheKey: Int] = [:]
    var inFlightRevalidation: [RevalidationSlot: RevalidationFetch] = [:]

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
            if let revalidated = await revalidateDiskHit(
                cached,
                key: key,
                cacheKey: cacheKey,
                candidates: candidates
            ) {
                await memoryCache.set(cacheKey, asset: revalidated)
                return revalidated
            }
            // The persisted entry failed re-validation against the
            // *current* format/magic/dimension/limits/decode contract
            // (see ``revalidateDiskHit``): it has already been quarantined
            // (removed from disk), so fall through to a fresh network
            // fetch exactly as if nothing had been cached at all, rather
            // than surfacing the stale/invalid bytes or poisoning this
            // call permanently.
        }
        return try await coalescedFetch(key: key, cacheKey: cacheKey, candidates: candidates)
    }

    /// Evicts every entry from both cache layers. Exposed for tests and for
    /// an explicit user-initiated "clear cache" action; never called
    /// automatically.
    func evictAll() async {
        await memoryCache.removeAll()
        await diskCache.removeAll()
    }

    // MARK: - Coalesced network fetch

    /// Tracks a single shared in-flight fetch and the still-registered
    /// waiters awaiting it, each identified by its own `UUID` and holding
    /// its own `CheckedContinuation`.
    ///
    /// A plain, non-`Sendable` value type living only as a dictionary
    /// value inside `inFlight` — never itself passed across a concurrency
    /// boundary. The spawned cancellation-cleanup and completion-watcher
    /// `Task`s below instead capture only genuinely `Sendable` values
    /// (`AssetCacheKey`, `UUID`, `Task<CachedAsset, Error>`) and hop back
    /// onto this actor (`cancelWaiter`/`completeFetch`) before ever
    /// touching `inFlight` again, so every read/mutation of this type is
    /// already serialized by actor isolation alone.
    ///
    /// Per-waiter continuations (rather than one shared `Task.value`) are
    /// the key correctness property here: they let a single cancelling
    /// waiter be resumed independently of whatever the shared fetch
    /// itself eventually does — including a shared fetch that goes on to
    /// succeed — rather than a cancelled waiter racing to observe (and
    /// wrongly receiving) a shared task's own successful result.
    private struct InFlightFetch {
        /// Distinguishes this exact fetch attempt from a later one that
        /// might reuse the same `AssetCacheKey` after this one is torn
        /// down, without needing `InFlightFetch` itself to be a
        /// reference type comparable by identity.
        let id = UUID()
        let task: Task<CachedAsset, Error>
        var waiters: [UUID: AssetContinuation] = [:]
    }

    private func coalescedFetch(
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate]
    ) async throws -> CachedAsset {
        let waiterID = UUID()
        let fetchID: UUID
        if let existing = inFlight[cacheKey] {
            fetchID = existing.id
        } else {
            let newTask = Task { [weak self] in
                guard let self else { throw CancellationError() }
                return try await fetchAndValidate(
                    key: key,
                    cacheKey: cacheKey,
                    candidates: candidates
                )
            }
            let newFetch = InFlightFetch(task: newTask)
            inFlight[cacheKey] = newFetch
            fetchID = newFetch.id
            Task { [weak self] in
                let result = await newTask.result
                await self?.completeFetch(cacheKey, fetchID: fetchID, result: result)
            }
        }

        return try await withTaskCancellationHandler {
            let result = await withCheckedContinuation { (continuation: AssetContinuation) in
                // Runs synchronously, before this function suspends, while
                // still isolated to this actor (`coalescedFetch` itself is
                // actor-isolated, and no other actor-isolated code can run
                // concurrently until the first genuine suspension below),
                // so registering directly into `inFlight`'s dictionary
                // here is race-free without any additional locking. Only
                // registers into a fetch that is still exactly this one
                // (`fetchID` match): if it was already torn down and
                // replaced between the check above and here, resuming with
                // a synthetic cancellation below is the correct outcome
                // for this waiter (there is nothing left to join).
                if inFlight[cacheKey]?.id == fetchID {
                    var fetch = inFlight[cacheKey]
                    fetch?.waiters[waiterID] = continuation
                    inFlight[cacheKey] = fetch
                } else {
                    continuation.resume(returning: .failure(CancellationError()))
                }
            }
            // Deterministically overrides to `CancellationError` for a
            // waiter whose own task was cancelled, regardless of whether
            // this waiter's cancellation cleanup (`cancelWaiter`, below)
            // happened to run before or after the shared fetch's own
            // completion (`completeFetch`) reached the actor — those two
            // hops race against each other with no ordering guarantee,
            // but `Task.isCancelled` is monotonic once set, so this check
            // is race-free even though the resumed `result` value alone
            // would not be.
            if Task.isCancelled {
                throw CancellationError()
            }
            return try result.get()
        } onCancel: {
            // `onCancel` may run synchronously on an arbitrary executor,
            // so this hops back onto the actor rather than touching
            // `inFlight` directly.
            Task { await self.cancelWaiter(cacheKey, fetchID: fetchID, waiterID: waiterID) }
        }
    }

    /// Removes exactly `waiterID` from the fetch identified by `fetchID`
    /// (if it is still the current entry for `key`) and resumes it,
    /// regardless of what the shared fetch itself later does. When this
    /// was the last remaining waiter, atomically (within this single
    /// actor-isolated call, before the underlying transport is ever told
    /// to cancel) removes the entry from `inFlight` so a caller arriving
    /// immediately afterward can never join a fetch that is already being
    /// torn down — it instead starts fresh work.
    private func cancelWaiter(_ key: AssetCacheKey, fetchID: UUID, waiterID: UUID) {
        guard var fetch = inFlight[key], fetch.id == fetchID else {
            // Already completed/replaced by the time this cancellation
            // reached the actor; the completion path already resumed (or
            // this waiter never actually registered) this waiter, so
            // there is nothing left to do here.
            return
        }
        if let continuation = fetch.waiters.removeValue(forKey: waiterID) {
            continuation.resume(returning: .failure(CancellationError()))
        }
        if fetch.waiters.isEmpty {
            inFlight[key] = nil
            fetch.task.cancel()
        } else {
            inFlight[key] = fetch
        }
    }

    /// Called exactly once by the shared fetch's own completion watcher.
    /// Resumes every still-registered waiter with the shared result, and
    /// clears `inFlight` only if the entry for `key` is still exactly the
    /// fetch identified by `fetchID` — a zero-waiter cancellation may
    /// already have removed (and possibly replaced with fresh work) this
    /// exact entry, in which case this stale completion must not touch
    /// newer state.
    private func completeFetch(
        _ key: AssetCacheKey,
        fetchID: UUID,
        result: Result<CachedAsset, Error>
    ) {
        guard let fetch = inFlight[key], fetch.id == fetchID else {
            // Already replaced (e.g. by a zero-waiter cancellation
            // followed by fresh work); that replaced entry's waiters (if
            // any) belong to the newer fetch and must not be touched by
            // this stale completion.
            return
        }
        inFlight[key] = nil
        for (_, continuation) in fetch.waiters {
            continuation.resume(returning: result)
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
                // See the identical decode gate in
                // ``assembleRevalidatedAsset`` for why a full platform
                // decode — not just the pure metadata/dimension parse
                // above — is required before publication. Offloaded via
                // ``decodeImageOffActor`` so this CPU-bound decode never
                // blocks unrelated cache requests on this actor.
                let decoded = try await decodeImageOffActor(response.body)
                guard decoded.width == validated.width, decoded.height == validated.height else {
                    throw AssetError.malformedImageData
                }
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
    func publish(_ cacheKey: AssetCacheKey, asset: CachedAsset) async {
        await memoryCache.set(cacheKey, asset: asset)
        await recordDiskPersistenceResult {
            try await diskCache.set(cacheKey, payload: asset.payload, metadata: asset.metadata)
        }
    }

    /// Refreshes an already-cached asset's metadata only (for example
    /// bumping `lastAccessedAt` after a 304 revalidation), without
    /// re-writing the unchanged payload bytes to disk. Falls back to the
    /// same best-effort, audited failure handling as ``publish(_:asset:)``.
    func touch(_ cacheKey: AssetCacheKey, asset: CachedAsset) async {
        await memoryCache.set(cacheKey, asset: asset)
        await recordDiskPersistenceResult {
            try await diskCache.touch(cacheKey, metadata: asset.metadata)
        }
    }

    private func recordDiskPersistenceResult(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            lastDiskPersistenceFailure = nil
        } catch let error as AssetError {
            lastDiskPersistenceFailure = error
        } catch {
            lastDiskPersistenceFailure = .cachePersistenceFailed(String(describing: error))
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        AssetPayloadHasher.sha256Hex(data)
    }

    /// Decodes `payload` on a genuine structured child task rather than
    /// synchronously on this actor's own executor, so a full platform
    /// image decode — whose CPU cost is not accounted for or bounded by
    /// ``AssetCacheLimits`` — never blocks unrelated cache
    /// requests/coalescing/cancellation handling for however long that
    /// decode takes.
    ///
    /// `async let` starts a real child task that inherits this call's
    /// cancellation (unlike a detached task): if the calling context is
    /// cancelled while this decode is still in flight, the awaited result
    /// below throws `CancellationError` at the next cooperative
    /// cancellation check rather than silently continuing to hold up the
    /// actor. Not `private`: shared by every call site across
    /// `AssetCacheService+Revalidation.swift` too.
    func decodeImageOffActor(_ payload: Data) async throws -> CGImage {
        async let decodedImage = AssetImageDecoder.decode(payload)
        return try await decodedImage
    }
}
