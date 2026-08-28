import Foundation

/// Per-profile and service-wide credential-epoch bookkeeping, serialized token-store
/// access, and durable cancellation-cleanup tombstone resolution.
///
/// Split out of `AppModel.swift` purely by file size; every member here operates on
/// exactly the same `@MainActor`-isolated state declared there (``AppModel/credentialEpochs``,
/// ``AppModel/globalCredentialEpoch``, ``AppModel/serviceResetBarrier``,
/// ``AppModel/tokenAccessQueues``, and ``AppModel/cleanupPendingTasks``) and is
/// documented together with them there.
extension AppModel {
    /// Serializes a durable ``TokenStore`` read, save, or delete for `profileID` behind
    /// any earlier one for the same profile that is still in flight, only actually
    /// running `operation` if `epoch` still matches ``credentialEpochs`` for
    /// `profileID`, and `globalEpoch` still matches ``globalCredentialEpoch``, at the
    /// instant it is about to run — also awaiting an active ``serviceResetBarrier``, if
    /// any is present at that instant, first.
    ///
    /// A generation check performed only before enqueueing, or only after an awaited
    /// call returns, is not enough to keep the token store itself consistent with the
    /// profile's *current* endpoint: an in-flight save may already be queued behind an
    /// endpoint edit's or removal's delete by the time that edit/removal invalidates
    /// the profile's credential epoch, so a generation check made when the save was
    /// *enqueued* can never observe that later invalidation. `epoch` must therefore be
    /// captured once, by the caller, at the same point its ``AppModel/generation`` is
    /// captured (operation start), and threaded through unchanged; this function then
    /// rechecks it against the live epoch immediately before `operation` runs — the
    /// last possible moment before the Keychain is actually touched — so an
    /// already-enqueued stale save can never durably resurrect a token for a
    /// since-changed or since-removed endpoint. The same reasoning applies to
    /// `globalEpoch` against a service-wide storage reset (``confirmStorageReset()``):
    /// capturing it once, at the same moment as `epoch`, and rechecking it here
    /// guarantees a reset that begins after this operation started — even one whose
    /// own drain-then-wipe sequence this operation ends up queued behind — is never
    /// raced by a save this operation was already committed to making. On either
    /// mismatch, `operation` is skipped and ``StaleCredentialEpochError`` is thrown;
    /// every call site treats this exactly like ``CancellationError`` (never surfaced
    /// as a user-facing failure).
    ///
    /// Beyond credential-epoch safety, this also preserves the existing ordering
    /// guarantee: durable mutations for a profile always apply in the order they were
    /// requested, and any later read for that profile always observes the effect of an
    /// earlier, still in-flight mutation rather than a stale value. Reads and writes
    /// for different profiles remain fully independent.
    @discardableResult
    func serializedTokenAccess<Value: Sendable>(
        for profileID: UUID,
        epoch: Int,
        globalEpoch: Int,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let previous = tokenAccessQueues[profileID]?.task
        // Captured synchronously, here — not dynamically re-read as `self
        // .serviceResetBarrier` inside the task body below — so this operation is
        // admitted exactly once, atomically with every other synchronous step in this
        // function, before any `await` can let a reset install a new barrier in
        // between. See the extended rationale on ``serviceResetBarrier`` itself.
        let admittedBarrier = serviceResetBarrier
        let scheduled = Task<Value, any Error> {
            await previous?.value
            if let admittedBarrier {
                await admittedBarrier.task.value
            }
            guard self.credentialEpochs[profileID, default: 0] == epoch,
                  self.globalCredentialEpoch == globalEpoch
            else {
                throw StaleCredentialEpochError()
            }
            return try await operation()
        }
        let tailID = UUID()
        let tail = Task { _ = try? await scheduled.value }
        tokenAccessQueues[profileID] = TokenAccessTail(id: tailID, task: tail)
        tokenAccessAdmissionHook?(profileID)
        defer {
            if tokenAccessQueues[profileID]?.id == tailID {
                tokenAccessQueues[profileID] = nil
            }
        }
        return try await scheduled.value
    }

    /// The current credential epoch for `profileID` (`0` if never invalidated), for a
    /// caller to capture once at the start of an operation alongside ``generation``.
    func currentCredentialEpoch(for profileID: UUID) -> Int {
        credentialEpochs[profileID, default: 0]
    }

    /// The current service-wide credential epoch, for a caller to capture once at the
    /// start of an operation alongside ``currentCredentialEpoch(for:)`` and
    /// ``generation``.
    func currentGlobalCredentialEpoch() -> Int {
        globalCredentialEpoch
    }

    /// Advances the credential epoch for `profileID` and returns the new value.
    ///
    /// Must be called synchronously, before enqueueing the delete that follows from
    /// the same invalidating event (an endpoint edit, a profile removal, a storage
    /// reset, or an explicit auth cancellation), so that no already-in-flight or
    /// not-yet-enqueued operation captured before this call can observe the new value
    /// as if it were its own — every other in-flight operation for this profile must
    /// have captured its epoch strictly earlier, and will therefore fail its recheck.
    @discardableResult
    func invalidateCredentialEpoch(for profileID: UUID) -> Int {
        let next = credentialEpochs[profileID, default: 0] + 1
        credentialEpochs[profileID] = next
        return next
    }

    /// Synchronously, unconditionally enqueues a token deletion for `profileID` behind
    /// whatever token-store operation is currently at the tail of its serialized
    /// queue — registering the new tail *before this function returns*, not merely
    /// inside a separately-scheduled ``Task``, so any operation that begins after this
    /// call returns (even one whose own async steps have not yet reached
    /// ``serializedTokenAccess(for:epoch:globalEpoch:_:)``) is guaranteed to be queued
    /// strictly behind this cleanup rather than racing ahead of, and being wiped by,
    /// it. Used by ``cancelAuthOperation()``, by
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
    /// (``cancelAuthOperation()``, ``interruptActiveAuthOperationIfNeeded()``) that
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
            defer {
                if self?.tokenAccessQueues[profileID]?.id == tailID {
                    self?.tokenAccessQueues[profileID] = nil
                }
                if self?.cleanupPendingTasks[profileID]?.id == tailID {
                    self?.cleanupPendingTasks[profileID] = nil
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
                return self?.tokenStoreFailure(from: error) ?? .other
            }
            // The delete succeeded (or found nothing to delete): only now may the
            // durable tombstone clear, and that clear itself must succeed before this
            // is reported as resolved — a clear failure here leaves the tombstone
            // pending (so a future ``resolvePendingCleanup(for:)`` retries this
            // already-idempotent delete and this clear) and is surfaced as a typed,
            // blocking failure exactly like a genuine delete failure, rather than
            // being silently swallowed while the durable record still names the
            // profile.
            guard let self else { return nil }
            do {
                try cleanupPendingStore.clearPending(profileID)
            } catch {
                return tokenStoreFailure(from: error)
            }
            return nil
        }
        let tail = Task { _ = await cleanupTask.value }
        tokenAccessQueues[profileID] = TokenAccessTail(id: tailID, task: tail)
        cleanupPendingTasks[profileID] = CleanupPendingTask(id: tailID, task: cleanupTask)
        tokenAccessAdmissionHook?(profileID)
        return .reserved(cleanupTask)
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
        let isPending: Bool
        do {
            isPending = try cleanupPendingStore.pendingProfileIDs().contains(profileID)
        } catch {
            return tokenStoreFailure(from: error)
        }
        guard isPending else { return nil }

        if let existing = cleanupPendingTasks[profileID] {
            return await existing.task.value
        }
        switch enqueueCancellationCleanup(
            for: profileID, globalEpoch: currentGlobalCredentialEpoch()
        ) {
        case let .reserved(task):
            return await task.value
        case let .markFailed(failure):
            return failure
        }
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
