import Foundation

/// The final, per-waiter acknowledgement step every coalesced-fetch and
/// coalesced-revalidation waiter must pass through immediately before it
/// is allowed to hand a success-shaped value back to its own external
/// caller — see ``coalescedFetch(key:cacheKey:candidates:)``/
/// ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:preIssuedAuthority:)``,
/// which each call `finalizeFetchWaiterOutcome`/`finalizeRevalidationWaiterOutcome`
/// exactly once, as the very last step before returning.
///
/// Closes a gap the prior design left open: once
/// ``AssetCacheService/completeFetch(_:fetchID:result:)``/
/// ``AssetCacheService/completeRevalidation(_:fetchID:result:)`` resumed
/// every currently-registered waiter's continuation with the shared
/// operation's own result, it unconditionally cleared `inFlight`/
/// `inFlightRevalidation` for that key in the very same step — so a
/// waiter whose own task happened to be cancelled at (or immediately
/// after) that exact moment, rather than while the underlying work was
/// still genuinely pending, correctly still observed `CancellationError`
/// itself (`Task.isCancelled` is monotonic once set, so that half was
/// always safe), but ``AssetCacheService/cancelWaiter(_:fetchID:waiterID:)``/
/// ``AssetCacheService/cancelRevalidationWaiter(_:fetchID:waiterID:)``
/// — the *only* code that ever retracted an already-applied mutation —
/// found the entry already gone and did nothing. The mutation the shared
/// operation had just applied was left fully readable to any later,
/// unrelated caller even though the sole caller who ever asked for it
/// walked away having received nothing but a cancellation. Per this
/// subsystem's own cancellation contract ("when the last waiter leaves,
/// cancellation may stop the fetch and must leave no partial cache
/// entry"), that mutation must never survive purely because nobody
/// happened to still be listening by the time it landed.
///
/// ``PendingWaiterAcknowledgement`` retains exactly the set of waiters a
/// completion watcher resumed, unresolved, until each one of them has
/// individually finalized (by success or by cancellation/staleness).
/// Only once every one of them has finalized — and only if not one
/// single one of them ever actually took delivery of the result — is the
/// shared mutation retracted, on behalf of the whole group, exactly
/// once.
///
/// Both ledgers (``AssetCacheService/pendingFetchAcknowledgement``/
/// ``AssetCacheService/pendingRevalidationAcknowledgement``) are keyed
/// by `fetchID` (a globally unique `UUID`, minted fresh for every
/// coalesced operation — see ``AssetCacheService/InFlightFetch/id``/
/// ``AssetCacheService/RevalidationFetch/id``) rather than by cache
/// key/slot: a *cache key alone* is not a safe dictionary key here,
/// because ``completeFetch(_:fetchID:result:)`` clears `inFlight[key]`
/// the instant it runs, letting an entirely new, independent coalesced
/// operation for that exact same key be created and itself complete
/// before this first operation's own stragglers have each finalized —
/// keying by cache key alone would let that second operation's ledger
/// entry silently overwrite (and thereby orphan tracking for) the
/// first's.
extension AssetCacheService {
    /// Bookkeeping for a coalesced fetch/revalidation whose underlying
    /// task has already completed and whose currently-registered waiters
    /// have already been resumed with the shared result, but who have
    /// not yet each individually finalized. See this file's own
    /// type-level doc comment for the exact hazard retaining this (rather
    /// than the prior unconditional-clear design) closes, and for why
    /// this is keyed by `fetchID` rather than by cache key/slot alone.
    struct PendingWaiterAcknowledgement<Key: Hashable> {
        let key: Key
        let token: CacheToken
        var pendingWaiterIDs: Set<UUID>
        var anyDelivered = false
    }

    /// The outcome ``finalizeFetchWaiterOutcome(_:waiter:token:currentEpoch:resultIsSuccess:)``/
    /// ``finalizeRevalidationWaiterOutcome(_:waiter:token:currentEpoch:resultIsSuccess:)``
    /// hands back to exactly one waiter.
    enum WaiterFinalOutcome {
        /// The underlying result was itself a failure (e.g. a transport
        /// error): the caller must propagate that original failure via
        /// `result.get()`, never a synthesized authority error — there is
        /// no cache mutation such a failure could ever have made that
        /// authority needs to protect.
        case failed
        /// This waiter's own task was cancelled by the time it reached
        /// this final check.
        case cancelled
        /// The underlying result was success, but this token is no
        /// longer authoritative for this key (superseded by a
        /// more-recently-issued operation, an individual invalidation, or
        /// a cache-wide `evictAll()`).
        case stale
        /// The underlying result was success and this token remains
        /// fully authoritative: safe to hand back to this waiter's own
        /// external caller.
        case delivered
    }

    /// Identifies exactly one waiter within exactly one coalesced
    /// operation's own ledger entry — a coalesced operation's globally
    /// unique ``PendingWaiterAcknowledgement`` ledger key (`fetchID`)
    /// paired with the specific waiter's own identity (`waiterID`)
    /// within that operation's set of resumed-but-unacknowledged
    /// waiters. Bundled into one type purely so
    /// ``finalizeFetchWaiterOutcome(_:waiter:token:currentEpoch:resultIsSuccess:)``/
    /// ``finalizeRevalidationWaiterOutcome(_:waiter:token:currentEpoch:resultIsSuccess:)``
    /// stay within this package's parameter-count convention.
    struct WaiterIdentity {
        let fetchID: UUID
        let waiterID: UUID
    }

    /// The single, terminal, actor-isolated decision point for exactly
    /// one coalesced-fetch waiter, called immediately after that waiter's
    /// continuation has resumed with the shared fetch's own `result` (see
    /// ``completeFetch(_:fetchID:result:)``). `currentEpoch` must already
    /// have been freshly read (``currentDurableClearEpoch()``) by the
    /// caller *before* this method is entered: the cancellation check,
    /// authority re-check, and this exact waiter's own ledger update
    /// below all still happen as one atomic block with no suspension
    /// point between them — `Task.isCancelled`, every synchronous
    /// authority field on `token`, and ``pendingFetchAcknowledgement``
    /// are read/mutated before this method's only `await` is ever
    /// reached, so no concurrently-arriving newer operation,
    /// `evictAll()`, or another waiter's own finalize call can interleave
    /// with *that* portion.
    ///
    /// `async` (unlike a prior revision of this method) specifically so
    /// that, when this exact waiter's own ledger update discovers it is
    /// the last one and no waiter in the group ever took delivery, this
    /// method can `await` the durable disk `.retiring` commit
    /// (``AssetCacheService/beginDurableRetractionIfApplied(_:token:)``)
    /// *before returning* — i.e. before this waiter's own cancellation/
    /// staleness outcome can ever be observed by its caller. A prior
    /// revision instead fired that retraction from a detached,
    /// unawaited `Task` and returned immediately, leaving a real window
    /// in which this waiter's own caller — or, worse, an entirely
    /// independent sibling process, or this same process after a crash —
    /// could still observe `key` as durably `.content` even though this
    /// method had already reported "cancelled/stale, nothing retained".
    /// Only the best-effort physical cleanup half of that retraction
    /// (phase 2) remains safely deferred to a detached `Task` — see
    /// ``AssetCacheService/beginDurableRetractionIfApplied(_:token:)``'s
    /// own doc comment for the full reasoning.
    func finalizeFetchWaiterOutcome(
        _ key: AssetCacheKey,
        waiter: WaiterIdentity,
        token: CacheToken,
        currentEpoch: Int?,
        resultIsSuccess: Bool
    ) async -> WaiterFinalOutcome {
        let cancelled = Task.isCancelled
        let authoritative = isTokenAuthoritative(token, for: key, currentEpoch: currentEpoch)
        let delivered = !cancelled && resultIsSuccess && authoritative
        let pendingRetraction = finalizePendingAcknowledgement(
            &pendingFetchAcknowledgement,
            fetchID: waiter.fetchID,
            waiterID: waiter.waiterID,
            delivered: delivered
        )
        if let pendingRetraction {
            await retractUndeliveredMutation(pendingRetraction.key, token: pendingRetraction.token)
        }
        if cancelled {
            return .cancelled
        }
        if !resultIsSuccess {
            return .failed
        }
        return delivered ? .delivered : .stale
    }

    /// Mirrors ``finalizeFetchWaiterOutcome(_:waiter:token:currentEpoch:resultIsSuccess:)``
    /// for a coalesced revalidation waiter — see that method's doc
    /// comment for the full reasoning; identical shape, the
    /// authority/ledger's `Key` is ``RevalidationSlot`` rather than
    /// ``AssetCacheKey`` alone (the authority check itself still uses
    /// `slot.cacheKey`, exactly like every other revalidation authority
    /// check in this subsystem).
    func finalizeRevalidationWaiterOutcome(
        _ slot: RevalidationSlot,
        waiter: WaiterIdentity,
        token: CacheToken,
        currentEpoch: Int?,
        resultIsSuccess: Bool
    ) async -> WaiterFinalOutcome {
        let cancelled = Task.isCancelled
        let authoritative = isTokenAuthoritative(
            token,
            for: slot.cacheKey,
            currentEpoch: currentEpoch
        )
        let delivered = !cancelled && resultIsSuccess && authoritative
        let pendingRetraction = finalizePendingAcknowledgement(
            &pendingRevalidationAcknowledgement,
            fetchID: waiter.fetchID,
            waiterID: waiter.waiterID,
            delivered: delivered
        )
        if let pendingRetraction {
            await retractUndeliveredMutation(
                pendingRetraction.key.cacheKey,
                token: pendingRetraction.token
            )
        }
        if cancelled {
            return .cancelled
        }
        if !resultIsSuccess {
            return .failed
        }
        return delivered ? .delivered : .stale
    }

    /// The exact same synchronous authority check ``isAuthoritative(_:for:)``
    /// performs, factored out so it can be combined, in one atomic
    /// actor-isolated step with no `await` in between, with the
    /// pending-acknowledgement ledger update above — `currentEpoch` is
    /// always the caller's own already-completed ``currentDurableClearEpoch()``
    /// read, never re-read here.
    private func isTokenAuthoritative(
        _ token: CacheToken,
        for key: AssetCacheKey,
        currentEpoch: Int?
    ) -> Bool {
        guard
            token.generation == globalGeneration,
            keyLatestToken[key] == token,
            token.clearGeneration == (keyClearGeneration[key] ?? 0),
            let tokenEpoch = token.durableClearEpoch,
            let currentEpoch,
            tokenEpoch == currentEpoch
        else {
            return false
        }
        return true
    }

    /// Shared bookkeeping update for exactly one waiter's finalize call,
    /// generic over the ledger's own key type so
    /// ``finalizeFetchWaiterOutcome(_:waiter:token:currentEpoch:resultIsSuccess:)``
    /// and ``finalizeRevalidationWaiterOutcome(_:waiter:token:currentEpoch:resultIsSuccess:)``
    /// can share one implementation despite tracking
    /// ``AssetCacheKey``/``RevalidationSlot`` respectively. Removes
    /// `waiterID` from the pending set and returns the original cache
    /// key/slot and the token whose mutation must now be retracted, but
    /// only if this was the last waiter remaining and not one single
    /// waiter across the whole group ever actually delivered — `nil`
    /// otherwise (nothing yet to retract).
    ///
    /// **Deliberately returns rather than performs the retraction
    /// itself** (a prior revision took a `retract` closure and invoked
    /// it synchronously, in-line, from right here). This method itself
    /// remains fully synchronous — no suspension between the ledger
    /// read/mutate above and this return — so its caller's own
    /// cancellation-check-plus-ledger-update atomicity is preserved
    /// exactly as before; only the caller, once back in its own `async`
    /// context, decides whether and how to `await` the retraction this
    /// return value describes.
    private func finalizePendingAcknowledgement<Key: Hashable>(
        _ ledger: inout [UUID: PendingWaiterAcknowledgement<Key>],
        fetchID: UUID,
        waiterID: UUID,
        delivered: Bool
    ) -> (key: Key, token: CacheToken)? {
        guard var pending = ledger[fetchID] else {
            // Never populated for this exact waiter -- e.g. `evictAll()`
            // resumes waiters directly, bypassing the completion watcher
            // (and this ledger) entirely, having already invalidated
            // every token's authority and cleared both cache layers
            // itself; there is nothing left here for this waiter to
            // retract.
            return nil
        }
        pending.pendingWaiterIDs.remove(waiterID)
        if delivered {
            pending.anyDelivered = true
        }
        guard pending.pendingWaiterIDs.isEmpty else {
            ledger[fetchID] = pending
            return nil
        }
        ledger[fetchID] = nil
        guard !pending.anyDelivered else { return nil }
        return (pending.key, pending.token)
    }

    /// Retracts a coalesced operation's own mutation from both cache
    /// layers once every one of its waiters has finalized without a
    /// single one of them ever taking delivery of it — a no-op if
    /// nothing was ever actually applied under `token`, or if a
    /// still-more-recent token has since superseded it (see
    /// ``AssetCacheService/beginDurableRetractionIfApplied(_:token:)``).
    /// Retiring `token` first closes the window against any *future*
    /// mutation this already-abandoned operation's own (already-
    /// completed) task body could otherwise still be mistaken for
    /// authoritative.
    ///
    /// ``markGenerationRetiring(_:for:)`` is called synchronously here,
    /// *before* this method's own `await` below, so a concurrent memory
    /// hit that races this retraction can never observe this exact entry
    /// as current in the window before phase 1 actually lands, nor in
    /// the (potentially much longer) window before such a reader gets
    /// around to its own authority check after already having captured
    /// this entry — see ``markGenerationRetiring(_:for:)``'s own doc
    /// comment for why this marker is therefore deliberately never
    /// eagerly cleared once this retraction's own removals complete,
    /// only ever pruned in bulk alongside the rest of `key`'s own
    /// bounded authority bookkeeping.
    ///
    /// **`await`ed directly by its sole caller
    /// (``finalizeFetchWaiterOutcome(_:waiter:token:currentEpoch:resultIsSuccess:)``/
    /// ``finalizeRevalidationWaiterOutcome(_:waiter:token:currentEpoch:resultIsSuccess:)``)
    /// for phase 1 (the durable disk `.retiring` commit) only** — a
    /// prior revision instead fired this whole retraction, phase 1
    /// included, from a detached, unawaited `Task` and let its caller
    /// return immediately, leaving a real window in which that waiter's
    /// own caller — or an entirely independent sibling process, or this
    /// same process after a crash — could still observe `key` as durably
    /// `.content` even after being told "cancelled/stale, nothing
    /// retained". Only phase 2 (the best-effort memory removal, physical
    /// disk deletion, and final `.tombstone` commit) remains safely
    /// deferred to a detached `Task` below: nothing depends on it having
    /// already completed by the time this method's own caller returns.
    ///
    /// **That detached `Task` captures `self` strongly, not weakly.** A
    /// prior revision used `Task { [weak self] in ... }` here, which can
    /// silently never run its body at all if this actor happens to
    /// deallocate (its last strong reference elsewhere released) before
    /// this detached `Task` is scheduled — abandoning phase 2 entirely,
    /// with no durable trace that it was ever supposed to happen. This
    /// alone is not what makes phase 1 itself durable across a crash or
    /// a genuinely separate process — that is
    /// ``AssetDiskCache/beginRetraction(_:token:)``'s own durable commit,
    /// already `await`ed above before this `Task` is even created — but
    /// it does close the narrower, still-real sub-case where phase 2's
    /// own best-effort cleanup is abandoned purely because this one
    /// process's own actor happened to deallocate first, strictly within
    /// that same process's own lifetime.
    private func retractUndeliveredMutation(_ key: AssetCacheKey, token: CacheToken) async {
        retireIfCurrent(token, for: key)
        markGenerationRetiring(token, for: key)
        await beginDurableRetractionIfApplied(key, token: token)
        Task {
            await self.completeDurableRetractionIfApplied(key, token: token)
        }
    }
}
