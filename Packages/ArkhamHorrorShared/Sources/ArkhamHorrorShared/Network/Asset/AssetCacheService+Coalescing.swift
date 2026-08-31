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
        let (fetchID, token) = await resolveOrCreateInFlightFetch(
            key: key,
            cacheKey: cacheKey,
            candidates: candidates
        )

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
            // `Task.isCancelled` alone is not consulted directly here:
            // ``finalizeFetchWaiterOutcome(_:waiter:token:currentEpoch:resultIsSuccess:)``
            // below reads it itself, as the very last step before this
            // waiter's outcome is decided — see that method's own doc
            // comment, and `AssetCacheService+WaiterAcknowledgement.swift`'s
            // type-level doc comment, for why folding the cancellation
            // check, the authority re-check, and this exact waiter's
            // ledger acknowledgement into that single synchronous actor
            // method (rather than three separate steps, as a prior
            // revision of this code had) is required: `Task.isCancelled`
            // is monotonic once set, so checking it there — after the
            // one durable epoch read below, immediately before the final
            // decision — already covers every window a cancellation
            // could have landed in since this waiter's continuation
            // resumed, including one landing during that epoch read
            // itself.
            //
            // `token` (captured above, before this shared fetch's `Task`
            // was even created) already carries its own fully-stamped
            // durable authority — both ``CacheToken/durableClearEpoch``
            // and ``CacheToken/diskWriteGeneration`` — from the
            // synchronous ``beginIssuance(for:)`` snapshot taken at
            // issuance time (see that method's doc comment): unlike a
            // prior revision of this code, there is no separate,
            // later-stamped copy to reconstruct here, since issuance
            // itself never leaves that window open in the first place.
            let currentEpoch = await currentDurableClearEpoch()
            let resultIsSuccess = if case .success = result {
                true
            } else {
                false
            }
            let outcome = finalizeFetchWaiterOutcome(
                cacheKey,
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
                // `.failed` propagates the shared fetch's own original
                // failure (never a synthesized authority error); a
                // failure never mutates the cache, so there is nothing
                // for authority to protect either way.
                return try result.get()
            }
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
    ///
    /// That protection alone is not sufficient: it only prevents a
    /// mutation this now-abandoned task has not *yet* performed. The
    /// shared task's own body may already have run ``publish(_:asset:token:)``
    /// (or ``touch(_:asset:token:)``) to full completion — including that
    /// call's own final authority re-check passing, since at that exact
    /// moment `fetch.token` genuinely was still authoritative — strictly
    /// *before* this exact cancellation ever reached this actor. Retiring
    /// `fetch.token` at that point closes the window against *future*
    /// mutations, but does nothing to the mutation that already landed:
    /// left alone, that entry would remain fully readable (a subsequent
    /// memory/disk hit for `key` would serve it, and legitimately so by
    /// every authority check those hits perform) even though the sole
    /// caller who asked for this work has already walked away. Per this
    /// subsystem's cancellation contract ("when the last waiter leaves,
    /// cancellation may stop the fetch and must leave no partial cache
    /// entry"), that is not acceptable merely because the underlying
    /// network round trip happened to race the cancellation and win:
    /// unconditionally retracting exactly `fetch.token`'s own mutation
    /// (via ``AssetMemoryCache/removeIfApplied(_:token:)``/
    /// ``AssetDiskCache/removeIfApplied(_:token:)`` — a no-op if nothing
    /// was ever actually applied under this exact token, or if a
    /// still-more-recent token has since superseded it) makes "no
    /// waiter left to observe it" and "no cache entry survives it"
    /// hold together deterministically, regardless of exactly how far
    /// the doomed task's own body had already run by the time this
    /// cancellation reached the actor. Performed here, synchronously
    /// with respect to `retireIfCurrent` and before `key` is left in a
    /// state any other caller could read from, rather than left to the
    /// doomed task's own (possibly already-passed) cancellation checks.
    /// The join-or-create decision for a normal (non-revalidation) cache
    /// miss, split out of ``coalescedFetch(key:cacheKey:candidates:)``
    /// purely to keep that function's body within this package's
    /// `function_body_length` limit. The entire decision below —
    /// including ``beginIssuance(for:)``'s durable disk-authority
    /// reservation, when this call ends up starting fresh work — runs
    /// under this key's decision lock (see
    /// `AssetCacheService+IssuanceDecisionLock.swift`'s type-level doc
    /// comment for exactly what hazard that closes): without it,
    /// ``beginIssuance(for:)``'s own suspension would let two concurrent
    /// calls for this same key each reserve a distinct disk ticket even
    /// though only one of them ever ends up actually used. Held only
    /// around this decision, never around the wait for the fetch's
    /// eventual result performed by the caller.
    private func resolveOrCreateInFlightFetch(
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate]
    ) async -> (fetchID: UUID, token: CacheToken) {
        let fetchID: UUID
        let token: CacheToken
        await acquireIssuanceDecisionLock(for: cacheKey)
        if let existing = inFlight[cacheKey] {
            fetchID = existing.id
            // The already-registered fetch's own token, issued when *it*
            // started — governs every one of its waiters uniformly, this
            // one included, never a freshly-derived token for this join
            // alone. Nothing was reserved for this join at all: no
            // `beginIssuance(for:)` call is made on this branch.
            token = existing.token
            releaseIssuanceDecisionLock(for: cacheKey)
        } else {
            // Read *before* this fresh fetch's token is issued — see
            // ``beginIssuance(for:)``'s doc comment for why this specific
            // ordering (rather than issuing a token first and stamping
            // its durable authority afterward, inside the `Task` that
            // performs this fetch's actual suspending work) is required.
            // Safe to call here (unlike a prior revision of this code)
            // because this key's decision lock, acquired above, is still
            // held: no other concurrent caller for this exact key can be
            // inside this same decision section to also call it and waste
            // a reservation.
            let authority = await beginIssuance(for: cacheKey)
            // Issued synchronously here — before the `Task` below is even
            // created, let alone runs — so this token's issuance order
            // exactly reflects the moment this fresh (never
            // coalesced-into) fetch was issued, per the issuance contract
            // in `AssetCacheService+Epoch.swift`. Every waiter that joins
            // this exact `inFlight` entry shares this one token. Stamped,
            // synchronously and completely, from `authority` (captured
            // above): no further `await` occurs between this token's
            // issuance and the moment it is fully authoritative-ready, so
            // there is no window during which a cross-instance/cross-
            // process clear or a competing write for this exact key could
            // land and never be reflected in this token's own authority.
            var issued = issueToken(for: cacheKey)
            issued.durableClearEpoch = authority.clearEpoch
            issued.diskWriteGeneration = authority.diskWriteGeneration
            token = issued
            let newTask = Task { [weak self] in
                guard let self else { throw CancellationError() }
                return try await fetchAndValidate(
                    key: key,
                    cacheKey: cacheKey,
                    candidates: candidates,
                    token: issued
                )
            }
            let newFetch = InFlightFetch(task: newTask, token: issued)
            inFlight[cacheKey] = newFetch
            fetchID = newFetch.id
            // Registered into `inFlight` before releasing the lock, so a
            // later caller for this same key that acquires the lock next
            // is guaranteed to find this entry already present.
            releaseIssuanceDecisionLock(for: cacheKey)
            Task { [weak self] in
                let result = await newTask.result
                await self?.completeFetch(cacheKey, fetchID: fetchID, result: result)
            }
        }
        return (fetchID, token)
    }

    private func cancelWaiter(_ key: AssetCacheKey, fetchID: UUID, waiterID: UUID) async {
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
            // Recorded synchronously, before either `await` below, so a
            // concurrent memory hit that races this cancellation (this
            // actor is reentrant across the suspensions immediately
            // following) can never observe this exact entry as current
            // in the window before these removals actually complete —
            // see ``AssetCacheService/retiringGenerations``'s own doc
            // comment for the full reasoning.
            markGenerationRetiring(fetch.token, for: key)
            fetch.task.cancel()
            await retractIfApplied(key, token: fetch.token)
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
    ///
    /// Registers exactly this set of resumed waiters into
    /// ``pendingFetchAcknowledgement`` *before* resuming any of them —
    /// see `AssetCacheService+WaiterAcknowledgement.swift`'s type-level
    /// doc comment for why this entry must be retained (rather than
    /// unconditionally forgotten here, as a prior revision of this
    /// method did) until each of these exact waiters has individually
    /// finalized via ``finalizeFetchWaiterOutcome(_:waiter:token:currentEpoch:resultIsSuccess:)``.
    /// No new waiter can ever register into this exact `fetchID` after
    /// this point: `resolveOrCreateInFlightFetch`'s registration closure
    /// only ever joins `inFlight[cacheKey]`, which this method clears
    /// synchronously, in this same step, before any waiter is resumed —
    /// so the waiter set captured here is already final.
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
        pendingFetchAcknowledgement[fetchID] = PendingWaiterAcknowledgement(
            key: key,
            token: fetch.token,
            pendingWaiterIDs: Set(fetch.waiters.keys)
        )
        testOnlyBeforeFetchResumesWaiters?()
        for (_, continuation) in fetch.waiters {
            continuation.resume(returning: result)
        }
    }
}
