import Foundation

/// Split out of `AssetCacheService+WaiterAcknowledgement.swift` purely to
/// stay under this package's file-length lint limit. Contains the
/// group-level side of the acknowledgement protocol that file's own
/// `finalizeFetchWaiterOutcome`/`finalizeRevalidationWaiterOutcome`
/// delegate to once a waiter's own ledger update
/// (`updateFetchAcknowledgementLedgerLocked`/
/// `updateRevalidationAcknowledgementLedgerLocked`) determines it is not
/// delivered: waiting for, or performing and broadcasting, this group's
/// one shared `GroupRetractionOutcome`. See that file's own type-level
/// doc comment for the full reasoning; this file assumes it as context.
extension AssetCacheService {
    /// The result of a single waiter's own synchronous ledger update —
    /// see ``updateFetchAcknowledgementLedgerLocked(fetchID:waiterID:delivered:)``/
    /// ``updateRevalidationAcknowledgementLedgerLocked(fetchID:waiterID:delivered:)``,
    /// which each construct this generically over their own ledger's
    /// key type.
    enum AcknowledgementLedgerDecision<Key: Hashable> {
        /// Nothing further to wait for: either this exact `fetchID` was
        /// never populated in the ledger at all (see
        /// ``updateFetchAcknowledgementLedgerLocked(fetchID:waiterID:delivered:)``'s
        /// own doc comment), or this waiter's own update already
        /// determined and broadcast the group's final outcome (there was
        /// nothing to retract, because some waiter in the group —
        /// possibly this very one — delivered).
        case resolved(GroupRetractionOutcome)
        /// This waiter is not (yet) the last one remaining in its group;
        /// its caller must register a continuation into this exact
        /// `fetchID`'s own `awaitingResolution` list and suspend until
        /// whichever waiter turns out to be last broadcasts this group's
        /// outcome.
        case waiting
        /// This waiter's own update was the one that emptied
        /// `pendingWaiterIDs`, and not one single waiter in the group
        /// ever delivered: this waiter itself must now perform the
        /// group's one, shared retraction attempt for `key`/`token`, and
        /// then broadcast its outcome to every continuation already
        /// registered in `waiting`.
        case mustRetract(
            key: Key,
            token: CacheToken,
            waiting: [CheckedContinuation<GroupRetractionOutcome, Never>]
        )
    }

    /// The exact same synchronous bookkeeping update a prior revision's
    /// single generic `finalizePendingAcknowledgement` performed —
    /// removes `waiterID` from the pending set and records whether it
    /// delivered — except this now additionally drives, from this one
    /// call site, both branches a later-arriving waiter needs: deciding
    /// whether *this* call must itself perform the group's retraction
    /// (``AcknowledgementLedgerDecision/mustRetract(key:token:waiting:)``,
    /// only ever true for whichever waiter's own update empties
    /// `pendingWaiterIDs` while `anyDelivered` is still `false`), must
    /// instead suspend behind a sibling's eventual retraction
    /// (``AcknowledgementLedgerDecision/waiting``), or has nothing left
    /// to wait for at all
    /// (``AcknowledgementLedgerDecision/resolved(_:)``) — including,
    /// when *this* call is the one that discovers the group's final
    /// disposition is "nothing to retract" (some waiter delivered),
    /// synchronously waking every sibling continuation already
    /// registered in ``PendingWaiterAcknowledgement/awaitingResolution``
    /// with ``GroupRetractionOutcome/notNeeded`` right here, in the same
    /// atomic step, rather than leaving them to discover that
    /// separately.
    ///
    /// Called for *every* waiter, delivered or not — see this file's
    /// own `finalizeFetchWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:)`
    /// own doc comment for why a delivered waiter's own ledger
    /// contribution must still land even though that waiter itself never
    /// awaits this decision. `delivered` being `true` here always makes
    /// `.mustRetract` unreachable for *this* call (setting
    /// `pending.anyDelivered = true` before the final guard below), so a
    /// delivered waiter's own returned decision — even if `.waiting` —
    /// is safe for that caller to simply discard without ever awaiting
    /// it.
    ///
    /// Remains fully synchronous — no suspension anywhere in this method
    /// — so its caller's own cancellation-check-plus-ledger-update
    /// atomicity is preserved exactly as before.
    func updateFetchAcknowledgementLedgerLocked(
        fetchID: UUID,
        waiterID: UUID,
        delivered: Bool
    ) -> AcknowledgementLedgerDecision<AssetCacheKey> {
        guard var pending = pendingFetchAcknowledgement[fetchID] else {
            // Never populated for this exact waiter -- e.g. `evictAll()`
            // resumes waiters directly, bypassing the completion watcher
            // (and this ledger) entirely, having already invalidated
            // every token's authority and cleared both cache layers
            // itself; there is nothing left here for this waiter to wait
            // on or retract.
            return .resolved(.notNeeded)
        }
        pending.pendingWaiterIDs.remove(waiterID)
        if delivered {
            pending.anyDelivered = true
        }
        guard pending.pendingWaiterIDs.isEmpty else {
            pendingFetchAcknowledgement[fetchID] = pending
            return .waiting
        }
        pendingFetchAcknowledgement[fetchID] = nil
        guard !pending.anyDelivered else {
            for continuation in pending.awaitingResolution {
                continuation.resume(returning: .notNeeded)
            }
            return .resolved(.notNeeded)
        }
        return .mustRetract(
            key: pending.key,
            token: pending.token,
            waiting: pending.awaitingResolution
        )
    }

    /// Mirrors ``updateFetchAcknowledgementLedgerLocked(fetchID:waiterID:delivered:)``
    /// for ``pendingRevalidationAcknowledgement`` — see that method's own
    /// doc comment for the full reasoning; identical shape, keyed by
    /// ``RevalidationSlot`` rather than ``AssetCacheKey`` alone.
    func updateRevalidationAcknowledgementLedgerLocked(
        fetchID: UUID,
        waiterID: UUID,
        delivered: Bool
    ) -> AcknowledgementLedgerDecision<RevalidationSlot> {
        guard var pending = pendingRevalidationAcknowledgement[fetchID] else {
            return .resolved(.notNeeded)
        }
        pending.pendingWaiterIDs.remove(waiterID)
        if delivered {
            pending.anyDelivered = true
        }
        guard pending.pendingWaiterIDs.isEmpty else {
            pendingRevalidationAcknowledgement[fetchID] = pending
            return .waiting
        }
        pendingRevalidationAcknowledgement[fetchID] = nil
        guard !pending.anyDelivered else {
            for continuation in pending.awaitingResolution {
                continuation.resume(returning: .notNeeded)
            }
            return .resolved(.notNeeded)
        }
        return .mustRetract(
            key: pending.key,
            token: pending.token,
            waiting: pending.awaitingResolution
        )
    }

    /// The async continuation of
    /// `updateFetchAcknowledgementLedgerLocked(fetchID:waiterID:delivered:)`'s
    /// own decision for a single non-delivered waiter: resolves
    /// immediately for `.resolved`, registers this exact call's own
    /// continuation and suspends for `.waiting`, or performs this
    /// group's one, shared retraction attempt and broadcasts its outcome
    /// to every already-registered sibling for `.mustRetract`. Only ever
    /// called for a `delivered == false` waiter — see this file's own
    /// `finalizeFetchWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:)`.
    func resolveFetchGroupRetraction(
        _ decision: AcknowledgementLedgerDecision<AssetCacheKey>,
        fetchID: UUID
    ) async -> GroupRetractionOutcome {
        switch decision {
        case let .resolved(outcome):
            return outcome
        case .waiting:
            return await withCheckedContinuation { continuation in
                // No suspension occurred between
                // ``updateFetchAcknowledgementLedgerLocked(fetchID:waiterID:delivered:)``'s
                // own return above and this synchronous registration —
                // this exact waiter's continuation can never be missed
                // by whichever sibling waiter's own call eventually
                // performs (or skips) this group's retraction.
                pendingFetchAcknowledgement[fetchID]?.awaitingResolution.append(continuation)
            }
        case let .mustRetract(key, token, waiting):
            let outcome = await performGroupRetraction(key, token: token)
            for continuation in waiting {
                continuation.resume(returning: outcome)
            }
            return outcome
        }
    }

    /// Mirrors ``resolveFetchGroupRetraction(_:fetchID:)`` for a
    /// coalesced revalidation waiter.
    func resolveRevalidationGroupRetraction(
        _ decision: AcknowledgementLedgerDecision<RevalidationSlot>,
        fetchID: UUID
    ) async -> GroupRetractionOutcome {
        switch decision {
        case let .resolved(outcome):
            return outcome
        case .waiting:
            return await withCheckedContinuation { continuation in
                pendingRevalidationAcknowledgement[fetchID]?.awaitingResolution.append(continuation)
            }
        case let .mustRetract(slot, token, waiting):
            let outcome = await performGroupRetraction(slot.cacheKey, token: token)
            for continuation in waiting {
                continuation.resume(returning: outcome)
            }
            return outcome
        }
    }

    /// Performs exactly one coalesced group's shared retraction attempt
    /// via ``retractUndeliveredMutation(_:token:)`` and converts its
    /// outcome into the typed ``GroupRetractionOutcome`` every waiter in
    /// that group — not merely whichever one happened to call this —
    /// must observe identically.
    func performGroupRetraction(
        _ key: AssetCacheKey,
        token: CacheToken
    ) async -> GroupRetractionOutcome {
        do {
            try await retractUndeliveredMutation(key, token: token)
            return .retracted
        } catch let error as AssetError {
            return .failed(error)
        } catch {
            return .failed(.cachePersistenceFailed(String(describing: error)))
        }
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
    /// (``finalizeFetchWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:)``/
    /// ``finalizeRevalidationWaiterOutcome(_:waiter:token:currentAuthority:resultIsSuccess:)``)
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
    func retractUndeliveredMutation(_ key: AssetCacheKey, token: CacheToken) async throws {
        retireIfCurrent(token, for: key)
        markGenerationRetiring(token, for: key)
        try await beginDurableRetractionIfApplied(key, token: token)
        Task {
            await self.completeDurableRetractionIfApplied(key, token: token)
        }
    }
}
