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
        /// Continuations for every waiter in this exact group that has
        /// already computed its own `delivered == false` outcome and is
        /// suspended waiting to learn this group's shared
        /// ``GroupRetractionOutcome`` — resumed exactly once each, by
        /// whichever waiter's own ledger update turns out to be the last
        /// one (see this file's own fetch/revalidation acknowledgement
        /// ledger update methods).
        /// **Closes this package's most recently flagged review finding:**
        /// a prior revision let only the logically-last waiter ever
        /// `await` this group's own retraction before returning its
        /// outcome; every earlier-finalizing, non-delivered waiter
        /// returned `.cancelled`/`.failed`/`.stale` to its own external
        /// caller immediately, with zero synchronization against whether
        /// that eventual, guaranteed-to-happen retraction ever actually
        /// succeeded — a caller could observe "nothing retained" while a
        /// fresh sibling/restart could still durably read the abandoned
        /// `content(ticket)` this group's mutation left behind. Every
        /// non-delivered waiter, not merely the last, now suspends here
        /// until the group's shared, one-time-computed outcome is
        /// broadcast to it.
        var awaitingResolution: [CheckedContinuation<GroupRetractionOutcome, Never>] = []
    }

    /// The one-time, shared outcome of a coalesced-fetch/-revalidation
    /// group's own attempt to retract an abandoned mutation — computed
    /// exactly once, by whichever waiter's own ledger update empties
    /// `pendingWaiterIDs` last, and then broadcast to every other
    /// non-delivered waiter in that same group (see
    /// ``PendingWaiterAcknowledgement/awaitingResolution``).
    enum GroupRetractionOutcome {
        /// No waiter in this group ever needed a retraction at all —
        /// either some waiter's own token was `.delivered`
        /// (``PendingWaiterAcknowledgement/anyDelivered``), or this
        /// group's ledger entry never existed in the first place (e.g.
        /// ``AssetCacheService/evictAll()`` already invalidated and
        /// cleared everything itself, bypassing this ledger entirely).
        case notNeeded
        /// This group's retraction was attempted and durably confirmed
        /// (or was itself a safe no-op — see
        /// ``AssetCacheService/retractUndeliveredMutation(_:token:)``'s
        /// own doc comment).
        case retracted
        /// This group's retraction was attempted but could not be
        /// durably confirmed. Every waiter that receives this — not only
        /// whichever one happened to attempt it — must report
        /// ``AssetCacheService/WaiterFinalOutcome/retractionNotDurable(_:)``,
        /// never a plain `.cancelled`/`.stale`/`.failed`.
        case failed(AssetError)
    }

    /// The outcome
    /// ``finalizeFetchWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:)``/
    /// ``finalizeRevalidationWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:)``
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
        /// This waiter was the last one remaining, no waiter in the
        /// group ever took delivery, and the group's own abandoned
        /// mutation's phase-1 durable retraction
        /// (``AssetCacheService/beginDurableRetractionIfApplied(_:token:)``)
        /// could not be confirmed. Must never be folded into
        /// `.cancelled`/`.stale`: those two both require this exact
        /// durable transition to have already landed (or to be already
        /// provably unnecessary) first — reporting either while this
        /// commit genuinely failed would let a caller believe "nothing
        /// was retained" while durable disk state may still say
        /// `.content`. The associated ``AssetError`` is the typed
        /// failure to propagate.
        case retractionNotDurable(AssetError)
    }

    /// Identifies exactly one waiter within exactly one coalesced
    /// operation's own ledger entry — a coalesced operation's globally
    /// unique ``PendingWaiterAcknowledgement`` ledger key (`fetchID`)
    /// paired with the specific waiter's own identity (`waiterID`)
    /// within that operation's set of resumed-but-unacknowledged
    /// waiters. Bundled into one type purely so
    /// ``finalizeFetchWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:)``/
    /// ``finalizeRevalidationWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:)``
    /// stay within this package's parameter-count convention.
    struct WaiterIdentity {
        let fetchID: UUID
        let waiterID: UUID
    }

    /// The single, terminal, actor-isolated decision point for exactly
    /// one coalesced-fetch waiter, called immediately after that waiter's
    /// continuation has resumed with the shared fetch's own `result` (see
    /// ``completeFetch(_:fetchID:result:)``). `currentAuthority` must
    /// already have been freshly read (``currentDurableKeyAuthority(for:)``)
    /// by the
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
    /// **Every non-delivered waiter, not merely the logically-last one,
    /// now suspends here until this group's shared
    /// ``GroupRetractionOutcome`` is known.** A prior revision only
    /// `await`ed the group's retraction from whichever waiter's own
    /// ledger update happened to empty `pendingWaiterIDs` last; every
    /// earlier-finalizing, non-delivered waiter read back `nil` from its
    /// own ledger update (nothing left *for it* to do) and returned its
    /// own precomputed `.cancelled`/`.failed`/`.stale` outcome
    /// immediately — with zero synchronization against whether that
    /// group's retraction, guaranteed to eventually run, ever actually
    /// succeeded. A caller could observe "nothing retained" while a
    /// fresh sibling instance/process (or this same process after a
    /// restart) could still durably read the abandoned `content(ticket)`
    /// this group's mutation left behind. See
    /// ``PendingWaiterAcknowledgement/awaitingResolution``'s own doc
    /// comment for the exact mechanism this now uses instead: this
    /// waiter's own ledger update
    /// (``updateFetchAcknowledgementLedgerLocked(fetchID:waiterID:delivered:)``)
    /// and, if it is not the group's own retracting waiter, its
    /// continuation's registration into that ledger entry, both happen
    /// synchronously with no suspension between them — so no
    /// concurrently-arriving sibling waiter's own finalize call can ever
    /// interleave with that portion and lose this exact waiter's
    /// eventual wakeup.
    ///
    /// A `delivered` waiter never enters this wait at all — see this
    /// method's own body: there is nothing this exact group could ever
    /// need to retract on behalf of a waiter that itself already took
    /// delivery, and a delivered waiter has no reason to depend on every
    /// sibling waiter (which may straggle far longer than this one) also
    /// having finished finalizing before it can return.
    func finalizeFetchWaiterOutcome(
        _ key: AssetCacheKey,
        waiter: WaiterIdentity,
        token: CacheToken,
        currentAuthority: AssetDiskCache.KeyAuthoritySnapshot?,
        resultIsSuccess: Bool
    ) async -> WaiterFinalOutcome {
        let cancelled = Task.isCancelled
        let authoritative = isTokenAuthoritative(
            token,
            for: key,
            currentAuthority: currentAuthority
        )
        let delivered = !cancelled && resultIsSuccess && authoritative
        // Always performed, delivered or not: the ledger's own
        // `pendingWaiterIDs`/`anyDelivered` bookkeeping must reflect
        // every waiter in the group, not only the non-delivered ones —
        // see ``updateFetchAcknowledgementLedgerLocked(fetchID:waiterID:delivered:)``'s
        // own doc comment.
        let decision = updateFetchAcknowledgementLedgerLocked(
            fetchID: waiter.fetchID,
            waiterID: waiter.waiterID,
            delivered: delivered
        )
        if !delivered {
            let resolution = await resolveFetchGroupRetraction(decision, fetchID: waiter.fetchID)
            if case let .failed(error) = resolution {
                return .retractionNotDurable(error)
            }
        }
        if cancelled {
            return .cancelled
        }
        if !resultIsSuccess {
            return .failed
        }
        return delivered ? .delivered : .stale
    }

    /// Mirrors ``finalizeFetchWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:)``
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
        currentAuthority: AssetDiskCache.KeyAuthoritySnapshot?,
        resultIsSuccess: Bool
    ) async -> WaiterFinalOutcome {
        let cancelled = Task.isCancelled
        let authoritative = isTokenAuthoritative(
            token,
            for: slot.cacheKey,
            currentAuthority: currentAuthority
        )
        let delivered = !cancelled && resultIsSuccess && authoritative
        let decision = updateRevalidationAcknowledgementLedgerLocked(
            fetchID: waiter.fetchID,
            waiterID: waiter.waiterID,
            delivered: delivered
        )
        if !delivered {
            let resolution = await resolveRevalidationGroupRetraction(
                decision,
                fetchID: waiter.fetchID
            )
            if case let .failed(error) = resolution {
                return .retractionNotDurable(error)
            }
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
    /// performs — except also requiring `token`'s own issued ticket to
    /// still be, or be entirely superseded only by abandoned tickets
    /// (``ticketGapIsEntirelyAbandoned(from:downTo:for:)``, the exact
    /// tolerance ``memoryEntryStillCurrent(_:storedGeneration:for:)``
    /// already applies to a memory-hit re-validation), the key's own
    /// current durable highest-*issued* ticket. `currentEpoch` alone
    /// (this method's prior signature) could never detect an
    /// independent sibling instance/process's own newer issuance for
    /// this exact key: two operations for the same key can be issued in
    /// one order and complete in another, and the epoch alone is
    /// unaffected by either — only this key's own durable issued-ticket
    /// counter reflects that a strictly newer operation now exists,
    /// regardless of whether it has completed yet. `currentAuthority` is
    /// always the caller's own already-completed
    /// ``currentDurableKeyAuthority(for:)`` read, never re-read here.
    private func isTokenAuthoritative(
        _ token: CacheToken,
        for key: AssetCacheKey,
        currentAuthority: AssetDiskCache.KeyAuthoritySnapshot?
    ) -> Bool {
        guard
            token.generation == globalGeneration,
            keyLatestToken[key] == token,
            token.clearGeneration == (keyClearGeneration[key] ?? 0),
            let tokenEpoch = token.durableClearEpoch,
            let tokenTicket = token.diskWriteGeneration,
            let currentAuthority,
            tokenEpoch == currentAuthority.clearEpoch,
            !writeGenerationIsRetiring(tokenTicket, epoch: tokenEpoch, for: key)
        else {
            return false
        }
        return ticketGapIsEntirelyAbandoned(
            from: currentAuthority.issuedTicket,
            downTo: tokenTicket,
            epoch: currentAuthority.clearEpoch,
            for: key
        )
    }
}
