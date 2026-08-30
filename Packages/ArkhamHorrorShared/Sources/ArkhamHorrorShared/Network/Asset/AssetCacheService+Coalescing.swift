import Foundation

/// The coalesced-in-flight-fetch machinery for a normal (non-revalidation)
/// cache miss: joining/starting a single shared network fetch per cache
/// key, and the per-waiter cancellation/completion bookkeeping that keeps
/// one waiter's cancellation from ever corrupting shared work or another
/// waiter's own result. Split out of the main actor file purely to stay
/// under this package's file-length limit; every member here is still
/// actor-isolated `AssetCacheService` state/behavior.
extension AssetCacheService {
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
    struct InFlightFetch {
        /// Distinguishes this exact fetch attempt from a later one that
        /// might reuse the same `AssetCacheKey` after this one is torn
        /// down, without needing `InFlightFetch` itself to be a
        /// reference type comparable by identity.
        let id = UUID()
        let task: Task<CachedAsset, Error>
        /// The authority token this exact fetch was issued under —
        /// retained so ``cancelWaiter(_:fetchID:waiterID:)`` can retire it
        /// (via ``retireIfCurrent(_:for:)``) the moment the last waiter
        /// for this fetch cancels, without needing to re-derive or
        /// re-look-up which token belongs to this specific attempt.
        let token: CacheToken
        var waiters: [UUID: AssetContinuation] = [:]
    }

    /// Test-only observability accessor: the number of still-registered
    /// waiters for the coalesced in-flight fetch (if any) currently
    /// tracked for `key`, re-deriving the exact same ``AssetCacheKey``
    /// ``asset(for:)`` itself computes. Exists purely so tests can
    /// synchronize on real actor-isolated state -- e.g. "a second waiter
    /// has genuinely joined this fetch" or "a cancelled waiter's cleanup
    /// has actually run" -- deterministically, rather than approximating
    /// either with a `Task.sleep` guess that scheduler jitter under load
    /// (observed in practice on constrained CI runners) can make wrong.
    /// Read-only and side-effect-free; harmless in a release build.
    func inFlightWaiterCount(for key: AssetKey) throws -> Int {
        let candidates = try resolvedCandidates(for: key)
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)
        return inFlight[cacheKey]?.waiters.count ?? 0
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
            // Issued synchronously here — before the `Task` below is even
            // created, let alone runs — so this token's issuance order
            // exactly reflects the moment this fresh (never
            // coalesced-into) fetch was issued, per the issuance contract
            // in `AssetCacheService+Epoch.swift`. Every waiter that joins
            // this exact `inFlight` entry shares this one token.
            let token = issueToken(for: cacheKey)
            let newTask = Task { [weak self] in
                guard let self else { throw CancellationError() }
                return try await fetchAndValidate(
                    key: key,
                    cacheKey: cacheKey,
                    candidates: candidates,
                    token: token
                )
            }
            let newFetch = InFlightFetch(task: newTask, token: token)
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
    /// torn down — it instead starts fresh work. That same zero-waiter
    /// case also retires `fetch.token` (via ``retireIfCurrent(_:for:)``)
    /// immediately before the task is cancelled: this shared task is a
    /// single continuous body of code, and Swift's cooperative task
    /// cancellation only takes effect at that task's *own* next
    /// suspension point / cancellation check, which may not have been
    /// reached yet at the exact moment this method runs. Retiring the
    /// token here closes that window synchronously and immediately,
    /// rather than relying solely on the doomed task eventually observing
    /// `Task.isCancelled` on its own: any ``AssetCacheService/publish(_:asset:token:)``/
    /// ``AssetCacheService/touch(_:asset:token:)``/
    /// ``AssetCacheService/invalidate(_:token:)`` call this now-abandoned
    /// task still goes on to make will find no token authoritative for
    /// `key` at all and correctly refuse to mutate shared state.
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
            retireIfCurrent(fetch.token, for: key)
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
}
