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

    /// Per-key mutation epoch and the shared global epoch, together
    /// forming the single authority every cache-mutating operation (a
    /// normal fetch's publish, a revalidation's 404/304/200 outcome, or
    /// ``evictAll()``) must check itself against immediately before ever
    /// touching memory/disk state — see `AssetCacheService+Epoch.swift`
    /// for the full ``CacheEpoch`` capture/CAS contract this replaces the
    /// old, revalidation-only generation counter with.
    var keyEpoch: [AssetCacheKey: Int] = [:]
    var globalEpoch = 0
    var inFlightRevalidation: [RevalidationSlot: RevalidationFetch] = [:]

    /// Keys whose disk entry this actor knows it *intended* to invalidate
    /// (a definitive 404, a failed re-validation quarantine, or
    /// ``evictAll()``) but where the underlying physical deletion could
    /// not be confirmed to have fully succeeded. ``AssetDiskCache``
    /// surfaces a deletion failure as a typed error rather than silently
    /// swallowing it (see its doc comment); this set is what keeps that
    /// typed failure from being a no-op here: a tombstoned key is treated
    /// as absent from disk regardless of what a subsequent
    /// ``AssetDiskCache/get(_:)`` might still be able to read back, so a
    /// deletion the filesystem could not physically complete can never
    /// let a stale/invalidated body be served again. Cleared only when a
    /// fresh, successful publish for that exact key later supersedes
    /// whatever the tombstone was protecting against.
    var tombstonedKeys: Set<AssetCacheKey> = []

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
        let candidates = try resolvedCandidates(for: key)
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)

        if let cached = await memoryCache.get(cacheKey) {
            return cached
        }
        // A tombstoned key means this actor already intended to invalidate
        // its disk entry (a 404, a failed re-validation quarantine, or
        // `evictAll()`) but could not confirm the physical deletion fully
        // succeeded — never trust a disk read for it, regardless of what
        // bytes might still physically be present, until a fresh publish
        // clears the tombstone.
        if !tombstonedKeys.contains(cacheKey), let cached = await diskCache.get(cacheKey) {
            let epoch = currentEpoch(for: cacheKey)
            if let revalidated = try await revalidateDiskHit(
                cached,
                key: key,
                cacheKey: cacheKey,
                candidates: candidates
            ) {
                // `revalidateDiskHit` suspends (a full platform decode);
                // re-check this key's epoch immediately before caching its
                // result back into memory, so a concurrent `evictAll()` or
                // definitive invalidation that ran during that suspension
                // can never be resurrected by this now-stale read.
                if isCurrentEpoch(epoch, for: cacheKey) {
                    await memoryCache.set(cacheKey, asset: revalidated)
                }
                return revalidated
            }
            // The persisted entry failed re-validation against the
            // *current* format/magic/dimension/limits/decode contract
            // (see ``revalidateDiskHit``): it has already been quarantined
            // (removed from disk), so fall through to a fresh network
            // fetch exactly as if nothing had been cached at all, rather
            // than surfacing the stale/invalid bytes or poisoning this
            // call permanently. `CancellationError` is not caught here:
            // ``revalidateDiskHit`` rethrows it rather than returning
            // `nil`, propagating straight out instead of falling through.
        }
        return try await coalescedFetch(key: key, cacheKey: cacheKey, candidates: candidates)
    }

    /// Evicts every entry from both cache layers. Exposed for tests and for
    /// an explicit user-initiated "clear cache" action; never called
    /// automatically.
    ///
    /// Bumps the shared global epoch *before* awaiting either cache
    /// layer's removal, so every operation already in flight (a normal
    /// fetch's eventual publish, or a revalidation's eventual 404/304/200
    /// outcome) that captured its epoch before this call can no longer
    /// pass its own CAS check once this returns — none of them can
    /// resurrect anything this call is in the middle of clearing. Also
    /// cancels every currently in-flight fetch/revalidation task itself
    /// (not merely invalidating their eventual epoch check), so a caller
    /// that asked to clear the cache does not keep paying for network
    /// work whose result is now guaranteed to be discarded.
    func evictAll() async {
        globalEpoch += 1
        for (_, fetch) in inFlight {
            fetch.task.cancel()
        }
        for (_, fetch) in inFlightRevalidation {
            fetch.task.cancel()
        }
        inFlight.removeAll()
        inFlightRevalidation.removeAll()
        await memoryCache.removeAll()
        do {
            try await diskCache.removeAll()
            tombstonedKeys.removeAll()
        } catch {
            // A partial disk removal failure does not invalidate the
            // epoch bump above (every in-flight/future operation is
            // already correctly gated by it), but this actor cannot prove
            // every entry was physically removed — keep every
            // currently-tracked key tombstoned (never narrower than
            // before) so a read cannot resurrect whatever could not be
            // deleted. Newly published keys after this point are not
            // affected: `publish`/`touch` always clear a key's own
            // tombstone on a fresh, successful write.
            lastDiskPersistenceFailure = error as? AssetError
                ?? .cachePersistenceFailed(String(describing: error))
        }
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

    /// Not `private`: also called from
    /// `AssetCacheService+Revalidation.swift`'s ``revalidate(for:)``, which
    /// falls through to an ordinary unconditional fetch when a disk-loaded
    /// entry fails current-contract re-validation and so has no valid
    /// basis left for a conditional request.
    func coalescedFetch(
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate]
    ) async throws -> CachedAsset {
        let waiterID = UUID()
        let fetchID: UUID
        if let existing = inFlight[cacheKey] {
            fetchID = existing.id
        } else {
            // Captured synchronously here — before the `Task` below is
            // even created, let alone runs — so it exactly reflects this
            // key's mutation epoch "at issuance" of this fresh (never
            // coalesced-into) fetch, per the epoch contract in
            // `AssetCacheService+Epoch.swift`.
            let epoch = currentEpoch(for: cacheKey)
            let newTask = Task { [weak self] in
                guard let self else { throw CancellationError() }
                return try await fetchAndValidate(
                    key: key,
                    cacheKey: cacheKey,
                    candidates: candidates,
                    epoch: epoch
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

    /// Publishes a resolved asset into both cache layers. The disk write
    /// is deliberately best-effort (an in-memory-only asset is still
    /// usable for the remainder of the process), but that decision is
    /// centralized here in an explicit `do`/`catch` — rather than a bare
    /// `try?` — so a persistence failure is captured in
    /// ``lastDiskPersistenceFailure`` for auditing/instrumentation instead
    /// of vanishing silently. A successful disk write always clears
    /// `cacheKey`'s tombstone (see ``tombstonedKeys``): a fresh, verified
    /// generation on disk supersedes whatever an earlier failed deletion
    /// was protecting against.
    func publish(_ cacheKey: AssetCacheKey, asset: CachedAsset) async {
        await memoryCache.set(cacheKey, asset: asset)
        await recordDiskPersistenceResult {
            try await diskCache.set(cacheKey, payload: asset.payload, metadata: asset.metadata)
        }
        if lastDiskPersistenceFailure == nil {
            tombstonedKeys.remove(cacheKey)
        }
    }

    /// Refreshes an already-cached asset's metadata only (for example
    /// bumping ``AssetCacheMetadata/accessSequence`` after a 304
    /// revalidation), without re-writing the unchanged payload bytes to
    /// disk. Falls back to the same best-effort, audited failure handling
    /// as ``publish(_:asset:)``.
    func touch(_ cacheKey: AssetCacheKey, asset: CachedAsset) async {
        await memoryCache.set(cacheKey, asset: asset)
        await recordDiskPersistenceResult {
            try await diskCache.touch(cacheKey, metadata: asset.metadata)
        }
    }

    /// Removes `cacheKey` from both cache layers, tombstoning it if the
    /// disk deletion could not be confirmed to fully succeed (see
    /// ``tombstonedKeys``). Centralizes every disk-invalidating call site
    /// (a definitive 404, a failed re-validation quarantine) so none of
    /// them can accidentally swallow a deletion failure the way a bare
    /// `try?`/best-effort `remove` used to.
    func invalidate(_ cacheKey: AssetCacheKey) async {
        await memoryCache.remove(cacheKey)
        do {
            try await diskCache.remove(cacheKey)
        } catch {
            tombstonedKeys.insert(cacheKey)
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
}
