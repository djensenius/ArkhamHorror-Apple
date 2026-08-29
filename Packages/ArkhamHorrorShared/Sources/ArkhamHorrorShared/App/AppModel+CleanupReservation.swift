import Foundation

/// Durable cancellation-cleanup tombstone reservation and resolution for a single
/// profile's token.
///
/// Split out of ``AppModel+CredentialEpoch.swift`` purely by file size; every member
/// here operates on exactly the same `@MainActor`-isolated state declared in
/// `AppModel.swift` (``AppModel/tokenAccessQueues``, ``AppModel/cleanupPendingTasks``,
/// ``AppModel/pendingCleanupFailures``, and ``AppModel/cleanupPendingStore``) and
/// builds directly on ``AppModel/serializedTokenAccess(for:epoch:globalEpoch:_:)`` and
/// ``AppModel/invalidateCredentialEpoch(for:)``, both defined there.
extension AppModel {
    /// Synchronously, unconditionally enqueues a token deletion for `profileID` behind
    /// whatever token-store operation is currently at the tail of its serialized
    /// queue — registering the new tail *before this function returns*, not merely
    /// inside a separately-scheduled ``Task``, so any operation that begins after this
    /// call returns (even one whose own async steps have not yet reached
    /// ``serializedTokenAccess(for:epoch:globalEpoch:_:)``) is guaranteed to be queued
    /// strictly behind this cleanup rather than racing ahead of, and being wiped by,
    /// it. Used by ``cancelAuthOperation(ownedBy:)``, by
    /// ``interruptActiveAuthOperationIfNeeded()`` (a profile switch or retry
    /// interrupting an in-flight sign-in/registration exactly as an explicit
    /// cancellation would), by ``resolvePendingCleanup(for:)`` retrying a
    /// still-pending cleanup, and by
    /// ``updateCustomProfile(_:displayName:rawURL:)``/``removeCustomProfile(_:)`` (an
    /// endpoint-changing edit or removal reserving the exact same durable tombstone
    /// and synchronous-admission guarantees before their own delete proceeds).
    ///
    /// Unlike ``serializedTokenAccess(for:epoch:globalEpoch:_:)``, this delete is not
    /// itself gated on a profile credential epoch: its entire purpose is to remove
    /// whatever a just-interrupted operation's save may already have written under the
    /// very epoch this call's own caller just bumped, so gating it on that epoch would
    /// make it a guaranteed no-op. It still respects an active service-wide reset
    /// barrier (admitted synchronously at enqueue time — see ``serviceResetBarrier``
    /// and ``serializedTokenAccess(for:epoch:globalEpoch:_:)``) and `globalEpoch`, so
    /// it can never race ``TokenStore/deleteAllTokens()``.
    ///
    /// Before enqueueing the delete itself, durably marks `profileID` pending in
    /// ``cleanupPendingStore`` — synchronously, here, as a first-class precondition of
    /// reservation rather than a best-effort side note — so even a process crash or
    /// restart before the delete below actually completes still leaves a durable
    /// record that this profile's token must not be trusted until a deletion is
    /// retried and actually succeeds (see ``resolvePendingCleanup(for:)``,
    /// ``beginAuthOperation(_:issueToken:)``, and
    /// ``restoreToken(profile:compatibility:generation:)``). If that mark cannot be
    /// made durable, no deletion is enqueued at all: this returns
    /// ``CleanupReservation/markFailed(_:)`` and every caller must treat the
    /// interruption/cancellation/reset it was attempting as *not* having safely
    /// happened — preserving its prior state and surfacing the typed failure — rather
    /// than proceeding as though an unprotected in-flight save were safely guarded.
    ///
    /// The tombstone is cleared *only* once the delete actually succeeds — never
    /// merely because an error was surfaced, a retry was pressed, a new auth attempt
    /// began, or the profile was switched away from or removed — and clearing it is
    /// itself a required, typed-failing step: a `clearPending` failure after a
    /// successful delete leaves the tombstone pending and is reported as a failure
    /// exactly like a delete failure would be, so a caller can never observe this as
    /// silently resolved while the durable record still names the profile.
    ///
    /// Returns a ``CleanupReservation``; fire-and-forget callers
    /// (``cancelAuthOperation(ownedBy:)``, ``interruptActiveAuthOperationIfNeeded()``) that
    /// only care whether reservation itself succeeded may switch on it without
    /// awaiting the enclosed task, but must never treat a case they do not recognize
    /// as success.
    @discardableResult
    func enqueueCancellationCleanup(
        for profileID: UUID, globalEpoch: Int
    ) -> CleanupReservation {
        do {
            try cleanupPendingStore.markPending(profileID)
        } catch {
            // Fail closed: no deletion is enqueued, and the caller must not proceed as
            // though this profile's in-flight save were now safely guarded.
            return .markFailed(tokenStoreFailure(from: error))
        }

        let previous = tokenAccessQueues[profileID]?.task
        // See the identical rationale in
        // ``serializedTokenAccess(for:epoch:globalEpoch:_:)``: captured synchronously
        // here, not dynamically re-read inside the task body, so this cleanup is
        // admitted exactly once, atomically with every other synchronous step in this
        // function.
        let admittedBarrier = serviceResetBarrier
        let scheduled = Task<Void, any Error> {
            await previous?.value
            if let admittedBarrier {
                await admittedBarrier.task.value
            }
            guard self.globalCredentialEpoch == globalEpoch else {
                throw StaleCredentialEpochError()
            }
            try await self.tokenStore.deleteToken(for: profileID)
        }

        let tailID = UUID()
        let cleanupTask = Task<TokenStoreFailure?, Never> { [weak self] in
            await self?.resolveCancellationCleanupOutcome(
                profileID: profileID, tailID: tailID, scheduled: scheduled
            )
        }
        let tail = Task { _ = await cleanupTask.value }
        tokenAccessQueues[profileID] = TokenAccessTail(id: tailID, task: tail)
        cleanupPendingTasks[profileID] = CleanupPendingTask(id: tailID, task: cleanupTask)
        tokenAccessAdmissionHook?(profileID)
        return .reserved(cleanupTask)
    }

    /// The body of the `cleanupTask` scheduled by
    /// ``enqueueCancellationCleanup(for:globalEpoch:)`` — split out purely to keep
    /// that function within reasonable size/complexity; see its own documentation for
    /// the full rationale behind every step here. Always prunes `profileID`'s
    /// ``tokenAccessQueues``/``cleanupPendingTasks`` entries on completion, but only if
    /// they still name `tailID` (a newer reservation for the same profile is solely
    /// responsible for its own tracking entries and outcome).
    private func resolveCancellationCleanupOutcome(
        profileID: UUID, tailID: UUID, scheduled: Task<Void, any Error>
    ) async -> TokenStoreFailure? {
        defer {
            if tokenAccessQueues[profileID]?.id == tailID {
                tokenAccessQueues[profileID] = nil
            }
            if cleanupPendingTasks[profileID]?.id == tailID {
                cleanupPendingTasks[profileID] = nil
            }
        }
        do {
            try await scheduled.value
        } catch is CancellationError {
            return nil
        } catch is StaleCredentialEpochError {
            // Superseded by a newer invalidation for this profile: that newer
            // cleanup (or save) is responsible for resolving the tombstone, so it
            // is deliberately left pending here rather than cleared.
            return nil
        } catch {
            return recordCleanupFailure(
                tokenStoreFailure(from: error), for: profileID, tailID: tailID
            )
        }
        // The delete succeeded (or found nothing to delete): only now may the
        // durable tombstone clear, and that clear itself must succeed before this
        // is reported as resolved — a clear failure here leaves the tombstone
        // pending (so a future ``resolvePendingCleanup(for:)`` retries this
        // already-idempotent delete and this clear) and is surfaced as a typed,
        // blocking failure exactly like a genuine delete failure, rather than
        // being silently swallowed while the durable record still names the
        // profile.
        do {
            try cleanupPendingStore.clearPending(profileID)
        } catch {
            return recordCleanupFailure(
                tokenStoreFailure(from: error), for: profileID, tailID: tailID
            )
        }
        // Both the delete and the tombstone clear succeeded: this profile's
        // cleanup is fully resolved, so any previously recorded failure for it
        // from *this* attempt specifically (never a newer one already superseding
        // it) is now stale and must no longer be surfaced.
        if cleanupPendingTasks[profileID]?.id == tailID {
            pendingCleanupFailures[profileID] = nil
        }
        return nil
    }

    /// Records `failure` as `profileID`'s observable retry obligation — but only if no
    /// newer cleanup attempt for the same profile has already superseded this one's
    /// own tracking entry — and returns it unchanged for the caller to propagate. A
    /// newer attempt is solely responsible for its own outcome.
    private func recordCleanupFailure(
        _ failure: TokenStoreFailure, for profileID: UUID, tailID: UUID
    ) -> TokenStoreFailure {
        if cleanupPendingTasks[profileID]?.id == tailID {
            pendingCleanupFailures[profileID] = PendingCleanupFailure(
                attemptID: tailID, failure: failure
            )
        }
        return failure
    }

    /// Reserves a durable cleanup deletion for `profile.id` (see
    /// ``enqueueCancellationCleanup(for:globalEpoch:)``) and, only if `profile` is
    /// exactly the profile whose sign-in/registration is currently active, interrupts
    /// that operation as part of the very *same* synchronous transaction — advancing
    /// ``generation``, cancelling and releasing ``operationTask``, and resetting
    /// ``operation``/``operationFailure`` — all before this call returns.
    ///
    /// Used by an endpoint-changing profile edit (``updateCustomProfile(_:displayName:rawURL:)``)
    /// and by profile removal (``removeCustomProfile(_:)``) so that an active auth
    /// operation for the profile being mutated is interrupted exactly once, atomically
    /// with the very reservation that protects its token, rather than via a second,
    /// independently fallible call to ``interruptActiveAuthOperationIfNeeded()`` after
    /// metadata has already been mutated/persisted. A profile-management caller must
    /// never call ``interruptActiveAuthOperationIfNeeded()`` (directly, or indirectly
    /// through ``selectProfile(_:)``) again for the same mutation: doing so would
    /// re-attempt `cleanupPendingStore.markPending` a second time for a profile ID
    /// whose reservation already succeeded — a second fallible durable write with
    /// nothing left to protect against, whose own, independent failure could leave
    /// already-persisted metadata (a removed/edited profile) paired with a
    /// still-active, never-interrupted auth operation and task.
    ///
    /// On a mark failure, nothing here is mutated at all — not ``generation``, not the
    /// credential epoch, not `operation`/`operationTask` — exactly like
    /// ``enqueueCancellationCleanup(for:globalEpoch:)`` alone; the caller must treat the
    /// edit/removal it was attempting as not having safely started.
    ///
    /// A profile's credential epoch is invalidated on every successful reservation
    /// (endpoint-changing edits and removals always need this, whether or not an auth
    /// operation happens to be active for it right now, so a save already queued
    /// behind this cleanup — for a profile with no in-flight sign-in at all — is still
    /// rejected at its recheck). The *additional* auth-operation interruption below is
    /// conditioned separately, only on `profile` being the one named by `sessionState`
    /// while ``operation`` is ``SessionOperation/signingIn``/``SessionOperation/registering``,
    /// exactly the same condition ``interruptActiveAuthOperationIfNeeded()`` itself
    /// checks — this function performs the equivalent of that check and mutation
    /// inline, using the *same* reservation, instead of issuing a second one.
    @discardableResult
    func reserveCleanupInterruptingActiveAuth(for profile: ServerProfile) -> CleanupReservation {
        let reservation = enqueueCancellationCleanup(
            for: profile.id, globalEpoch: currentGlobalCredentialEpoch()
        )
        guard case .reserved = reservation else { return reservation }
        invalidateCredentialEpoch(for: profile.id)
        guard case let .signedOut(activeProfile, _) = sessionState,
              activeProfile.id == profile.id
        else {
            return reservation
        }
        guard operation == .signingIn || operation == .registering else { return reservation }
        generation += 1
        operationTask?.cancel()
        operationTask = nil
        operation = .idle
        operationFailure = nil
        return reservation
    }

    /// Resolves any durable cleanup-pending tombstone for `profileID`, retrying the
    /// token deletion it records if necessary, before a caller trusts/reads an
    /// existing token or saves a new one for it. Returns a typed failure (leaving the
    /// tombstone in place) when cleanup could not be completed — including when even
    /// retrying the reservation's durable mark fails — or returns `nil` once no
    /// cleanup is pending — whether none ever was, or this call just completed one —
    /// and the caller may proceed.
    ///
    /// Never merely consumes/clears the tombstone based on the *caller's* outcome (an
    /// error surfaced, a Retry press, a new auth attempt, a profile switch, or a
    /// process restart): only ``enqueueCancellationCleanup(for:globalEpoch:)``'s own
    /// successful (or not-found) delete, immediately followed by its own successful
    /// clear, resolves it. A durable-store read failure here is treated as "cleanup
    /// pending" (fail closed), never as "assume clean".
    func resolvePendingCleanup(for profileID: UUID) async -> TokenStoreFailure? {
        guard let pendingIDs = pendingCleanupRegistryIDs() else {
            // The registry itself could not be safely enumerated:
            // `pendingCleanupRegistryIDs()` has already transitioned `sessionState`
            // to `.credentialCleanupRegistryCorrupted` — a systemic failure of the
            // shared tombstone service, not this one profile's own cleanup. Every
            // caller must still treat this as "cleanup could not be resolved" (no
            // credential read/save/restore may proceed for `profileID`) but must not
            // overwrite that session-wide state with its own narrower, per-profile
            // presentation; see ``AppModel/isCredentialCleanupRegistryCorrupted``.
            return .other
        }
        guard pendingIDs.contains(profileID) else {
            // Genuinely resolved (or never pending) per the durable tombstone
            // registry itself — the ultimate source of truth every caller here
            // relies on — so any previously recorded observable failure for this
            // profile is now stale and must not keep being surfaced.
            pendingCleanupFailures[profileID] = nil
            return nil
        }

        if let existing = cleanupPendingTasks[profileID] {
            return await existing.task.value
        }
        switch enqueueCancellationCleanup(
            for: profileID, globalEpoch: currentGlobalCredentialEpoch()
        ) {
        case let .reserved(task):
            return await task.value
        case let .markFailed(failure):
            // No task was ever reserved (there is nothing to await), so — unlike the
            // `.reserved` branch above, whose own eventual completion records this
            // through `recordCleanupFailure` regardless of which caller triggered
            // it — this is the *only* place a mark failure can ever become visible.
            // Recorded centrally, here, so every caller (including a fire-and-forget
            // launch-time reconciliation `Task` that only ever discards this
            // function's return value) leaves the profile's obligation visible and
            // retryable rather than silently dropping it. Never gated on a
            // previously superseded attempt (there is no earlier reservation for
            // this profile in flight to protect): a durable tombstone still names
            // `profileID` in ``cleanupPendingStore`` regardless, so recording this
            // unconditionally can never resurrect an already-resolved obligation —
            // at worst it is immediately superseded by a later attempt's own
            // outcome, exactly like any other entry in ``pendingCleanupFailures``.
            pendingCleanupFailures[profileID] = PendingCleanupFailure(
                attemptID: UUID(), failure: failure
            )
            return failure
        }
    }

    /// Retries a previously reserved cancellation cleanup that ultimately failed for
    /// `profileID`, surfaced via ``pendingCleanupFailures``.
    ///
    /// The underlying durable tombstone (``TokenCleanupPendingStore``) already blocks
    /// any read, restore, or save for this profile regardless of whether this is ever
    /// called — ``resolvePendingCleanup(for:)`` enforces that unconditionally — but
    /// without a visible, user-actionable retry there would otherwise be no way to
    /// force a repeatedly failing cleanup to resolve. Delegates entirely to
    /// ``resolvePendingCleanup(for:)`` (which itself calls
    /// ``enqueueCancellationCleanup(for:globalEpoch:)`` unless a cleanup for this
    /// profile is already in flight), whose own completion records or clears
    /// ``pendingCleanupFailures`` exactly as any other cleanup attempt's would — a
    /// caller such as a "Retry" button need not duplicate that bookkeeping.
    @discardableResult
    func retryPendingCleanup(for profileID: UUID) async -> TokenStoreFailure? {
        await resolvePendingCleanup(for: profileID)
    }
}

/// Thrown by ``AppModel/serializedTokenAccess(for:epoch:globalEpoch:_:)`` when a queued
/// token operation's captured epoch no longer matches the profile's current credential
/// epoch. Carries no data and is always treated exactly like ``CancellationError``: it
/// must never be surfaced as a user-facing failure.
struct StaleCredentialEpochError: Error {}

/// The outcome of attempting to durably reserve (mark pending) and enqueue a
/// cancellation-cleanup deletion for a profile. See
/// ``AppModel/enqueueCancellationCleanup(for:globalEpoch:)``.
enum CleanupReservation {
    /// The tombstone was durably marked and the deletion was enqueued. Awaiting the
    /// associated task yields the eventual delete/clear outcome: `nil` once resolved,
    /// or a typed failure if either step could not complete (in which case the
    /// tombstone remains pending and is retryable).
    case reserved(Task<TokenStoreFailure?, Never>)
    /// The tombstone could not be durably marked; no deletion was enqueued. The
    /// caller must not proceed as though this profile's cleanup were safely
    /// underway — it must preserve its prior state, surface this typed failure, and
    /// allow the triggering action to be retried.
    case markFailed(TokenStoreFailure)
}
