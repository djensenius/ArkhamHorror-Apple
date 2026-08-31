import Foundation

/// Cancellation (`cancelWaiter`) and completion (`completeFetch`) for a
/// coalesced plain-fetch — split out of
/// `AssetCacheService+Coalescing.swift` purely to keep that file within
/// this package's `file_length` convention; still part of the single
/// `AssetCacheService` actor's isolated state.
extension AssetCacheService {
    /// Removes exactly this one waiter from the shared fetch identified
    /// by `fetchID`. If it was the last still-registered waiter, the
    /// shared fetch is torn down: the underlying `Task` is cancelled, and
    /// this key's write-generation is durably marked retiring (phase 1)
    /// before this waiter is told the outcome — see
    /// ``AssetCacheService/beginDurableRetractionIfApplied(_:token:)``'s
    /// own doc comment for why this exact ordering is required.
    func cancelWaiter(_ key: AssetCacheKey, fetchID: UUID, waiterID: UUID) async {
        guard var fetch = inFlight[key], fetch.id == fetchID else {
            // Already completed/replaced by the time this cancellation
            // reached the actor; the completion path already resumed (or
            // this waiter never actually registered) this waiter, so
            // there is nothing left to do here.
            return
        }
        guard let continuation = fetch.waiters.removeValue(forKey: waiterID) else {
            inFlight[key] = fetch
            return
        }
        guard fetch.waiters.isEmpty else {
            inFlight[key] = fetch
            continuation.resume(returning: .failure(CancellationError()))
            return
        }
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
        // Phase 1 -- the durable disk `.retiring` commit -- is awaited
        // to completion here, *before* this exact waiter's own
        // continuation is resumed below: see
        // ``AssetCacheService/beginDurableRetractionIfApplied(_:token:)``'s
        // own doc comment for why letting this waiter (or any other
        // reader, in this process or a sibling one) observe cancellation
        // while disk still durably says `.content` is exactly the defect
        // this ordering closes. Only the best-effort physical cleanup
        // and final `.tombstone` commit (phase 2) remain safe to finish
        // asynchronously, after this waiter has already been told the
        // outcome.
        //
        // If phase 1 itself cannot be durably confirmed, this waiter
        // must never be told plain cancellation regardless -- durable
        // disk state may still say `.content` -- so it is instead
        // resumed with the typed failure directly (never folded into
        // `CancellationError()`).
        do {
            try await beginDurableRetractionIfApplied(key, token: fetch.token)
            continuation.resume(returning: .failure(CancellationError()))
        } catch {
            continuation.resume(returning: .failure(error))
        }
        Task { await self.completeDurableRetractionIfApplied(key, token: fetch.token) }
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
    /// finalized via
    /// `finalizeFetchWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:)`.
    /// No new waiter can ever register into this exact `fetchID` after
    /// this point: `resolveOrCreateInFlightFetch`'s registration closure
    /// only ever joins `inFlight[cacheKey]`, which this method clears
    /// synchronously, in this same step, before any waiter is resumed —
    /// so the waiter set captured here is already final.
    func completeFetch(
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
