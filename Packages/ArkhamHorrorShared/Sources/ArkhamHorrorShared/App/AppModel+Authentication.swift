import Foundation

/// Sign-in and registration: authenticate or register, validate the returned token via
/// `whoami`, and only then durably save it. Signed-in is never exposed unless the save
/// succeeds, and credentials/registration details are never stored on `self`.
extension AppModel {
    /// Authenticates with `credentials` on the currently selected (usable) server.
    ///
    /// Only valid from ``SessionState/signedOut(profile:compatibility:)``. `credentials`
    /// is passed through to the injected session and never stored on `self`.
    func signIn(_ credentials: AuthenticationCredentials) {
        beginAuthOperation(.signingIn) { [authenticationSession] profile in
            try await authenticationSession.authenticate(credentials, on: profile)
        }
    }

    /// Registers a new account with `details` on the currently selected (usable) server.
    ///
    /// Only valid from ``SessionState/signedOut(profile:compatibility:)``. `details` is
    /// passed through to the injected session and never stored on `self`.
    func register(_ details: RegistrationDetails) {
        beginAuthOperation(.registering) { [authenticationSession] profile in
            try await authenticationSession.register(details, on: profile)
        }
    }

    func beginAuthOperation(
        _ operationKind: SessionOperation,
        issueToken: @escaping @Sendable (ServerProfile) async throws -> AuthToken
    ) {
        guard case let .signedOut(profile, compatibility) = sessionState else { return }
        guard operation == .idle else { return }
        operationTask?.cancel()
        generation += 1
        let currentGeneration = generation
        let currentGlobalEpoch = currentGlobalCredentialEpoch()
        operation = operationKind
        operationFailure = nil
        operationTask = Task { [weak self] in
            await self?.beginAuthOperationAfterResolvingCleanup(
                profile: profile,
                compatibility: compatibility,
                generation: currentGeneration,
                globalEpoch: currentGlobalEpoch,
                issueToken: issueToken
            )
        }
    }

    /// Resolves any durable cancellation-cleanup tombstone left pending for `profile`
    /// — even one whose in-memory tracking did not survive a process restart — before
    /// this operation is allowed to reach
    /// ``performAuthOperation(profile:compatibility:epochContext:issueToken:)``'s
    /// durable save. Without this, a token a previously cancelled operation's cleanup
    /// failed (or never got to attempt) to remove could otherwise be overwritten or
    /// raced by this operation's own save rather than being reliably deleted first.
    ///
    /// The credential epoch is captured only *after* this resolves — not synchronously
    /// in ``beginAuthOperation(_:issueToken:)`` — so this operation's own epoch
    /// capture can never itself be the value a cleanup this call just completed (or a
    /// barrier it awaited) would have seen as stale.
    private func beginAuthOperationAfterResolvingCleanup(
        profile: ServerProfile,
        compatibility: ServerCompatibility,
        generation: Int,
        globalEpoch: Int,
        issueToken: @Sendable (ServerProfile) async throws -> AuthToken
    ) async {
        if let failure = await resolvePendingCleanup(for: profile.id) {
            guard isCurrent(generation) else { return }
            operation = .idle
            operationFailure = .tokenStore(failure)
            return
        }
        guard isCurrent(generation) else { return }
        let credentialEpoch = currentCredentialEpoch(for: profile.id)
        await performAuthOperation(
            profile: profile,
            compatibility: compatibility,
            epochContext: CredentialOperationContext(
                generation: generation, credentialEpoch: credentialEpoch, globalEpoch: globalEpoch
            ),
            issueToken: issueToken
        )
    }

    /// Authenticates or registers, validates the returned token via `whoami`, and only
    /// then durably saves it. Signed-in is never exposed unless the save succeeds.
    func performAuthOperation(
        profile: ServerProfile,
        compatibility: ServerCompatibility,
        epochContext: CredentialOperationContext,
        issueToken: @Sendable (ServerProfile) async throws -> AuthToken
    ) async {
        let generation = epochContext.generation
        let issuedToken: AuthToken
        do {
            issuedToken = try await issueToken(profile)
        } catch {
            guard isCurrent(generation) else { return }
            operation = .idle
            operationFailure = authOperationFailure(from: error)
            return
        }
        // Re-checked after every awaited auth result (not just in each `catch`) so a
        // superseded operation is abandoned before it can reach the durable save below.
        guard isCurrent(generation) else { return }

        let user: CurrentUser
        do {
            let token = issuedToken.token
            user = try await authenticationSession.currentUser(on: profile, token: token)
        } catch {
            guard isCurrent(generation) else { return }
            operation = .idle
            operationFailure = authOperationFailure(from: error)
            return
        }
        guard isCurrent(generation) else { return }

        do {
            // `serializedTokenAccess` guarantees this save cannot be reordered by, or
            // race with, an in-flight save/delete/read for the same profile even if
            // this operation is superseded (e.g. a profile switch away and back) while
            // the save is already under way. Passing `credentialEpoch` additionally
            // guarantees that if an endpoint edit, removal, or explicit cancellation
            // has invalidated this profile's credential epoch since this operation
            // started — even one that is enqueued *after* this save but completes its
            // own invalidation before this save's closure actually runs — this save is
            // skipped rather than durably resurrecting a token for a stale origin.
            try await serializedTokenAccess(
                for: profile.id,
                epoch: epochContext.credentialEpoch,
                globalEpoch: epochContext.globalEpoch
            ) { [tokenStore] in
                try await tokenStore.save(issuedToken.token, for: profile.id)
            }
        } catch {
            guard isCurrent(generation) else { return }
            operation = .idle
            operationFailure = (error is CancellationError || error is StaleCredentialEpochError)
                ? nil
                : .tokenStore(tokenStoreFailure(from: error))
            return
        }

        guard isCurrent(generation) else { return }
        operation = .idle
        operationFailure = nil
        sessionState = .signedIn(profile: profile, compatibility: compatibility, user: user)
    }

    /// Cancels the in-flight sign-in or registration operation, if any, and returns to
    /// signed-out.
    ///
    /// Cancelling the underlying task alone is not sufficient: an injected
    /// authentication session that does not itself observe cancellation could still
    /// complete and reach the durable token save after this method returns. This
    /// method therefore also advances ``generation`` (so any subsequent completion of
    /// the cancelled task's steps is rejected by its `isCurrent` checks) and
    /// invalidates the profile's credential epoch (so even a save that has *already*
    /// passed those checks and is queued in
    /// ``serializedTokenAccess(for:epoch:globalEpoch:_:)`` is skipped rather than
    /// durably saving a token after the user has cancelled) — but only once the
    /// durable cleanup reservation this depends on has actually succeeded (see
    /// ``interruptActiveAuthOperationIfNeeded()``).
    ///
    /// Neither of those alone closes every window: a save can reach the durable
    /// mutation boundary, pass its epoch recheck, and either still be writing to the
    /// Keychain or have just finished writing when cancellation arrives — in both
    /// cases the epoch bump above cannot undo an already-in-progress or
    /// already-applied write. This method therefore also unconditionally enqueues a
    /// cleanup deletion for the profile (see
    /// ``enqueueCancellationCleanup(for:globalEpoch:)``), synchronously registered
    /// into the same per-profile serialized queue *before this method returns*, so it
    /// is guaranteed to run after (and remove the effect of) any save this
    /// cancellation could not itself have prevented, and strictly before any
    /// subsequent same-profile operation that starts afterward.
    ///
    /// Valid only while ``operation`` is ``SessionOperation/signingIn`` or
    /// ``SessionOperation/registering`` from ``SessionState/signedOut(profile:compatibility:)``;
    /// otherwise a no-op, so redundant calls (e.g. a Cancel button tap racing a
    /// just-completed sign-in, or an idempotent view-disappearance callback after
    /// successful navigation) are always safe — a successfully established session
    /// (``SessionState/signedIn(profile:compatibility:user:)``) can never be undone by
    /// this method, since by then ``operation`` is no longer ``signingIn``/``registering``.
    ///
    /// If the cleanup this cancellation depends on cannot be durably reserved (see
    /// ``AuthInterruptionOutcome/blocked(_:)``), this method does **not** present
    /// cancellation as having succeeded and does **not** mutate anything: the
    /// genuinely active operation's ``operationTask``, ``generation``, credential
    /// epoch, ``operation``, and ``sessionState`` are all left exactly as they were —
    /// it only surfaces the typed failure via ``operationFailure`` instead, so the UI
    /// shows an actionable, retryable error rather than either silently returning to
    /// signed-out while an in-flight save remains unprotected, or discarding the live
    /// task handle into a taskless, un-completable ``signingIn``/``registering`` state.
    /// Only once reservation succeeds is the underlying task actually cancelled and
    /// released, since only then is it safe to do so (a stale in-flight step can no
    /// longer mutate state once ``generation``/the credential epoch have been
    /// advanced, and any save it may already have applied is durably queued for
    /// removal).
    ///
    /// Returns `true` once there is no longer an active sign-in/registration for the
    /// caller to worry about (there was none to begin with, or this call's own
    /// reservation succeeded and it has been cleanly interrupted) — safe for a caller
    /// such as ``SignInView``/``RegisterView`` to treat as "cancellation is safe to
    /// dismiss for." Returns `false` only when a genuinely active operation could not
    /// be safely interrupted because its cleanup reservation failed
    /// (``AuthInterruptionOutcome/blocked(_:)``): the operation remains exactly as it
    /// was and the caller must **not** dismiss/navigate away, since doing so would
    /// abandon an unprotected in-flight save; ``operationFailure`` is already set for
    /// the UI to surface.
    @discardableResult
    func cancelAuthOperation() -> Bool {
        guard case let .signedOut(profile, compatibility) = sessionState else { return true }
        guard operation == .signingIn || operation == .registering else { return true }
        switch interruptActiveAuthOperationIfNeeded() {
        case .none:
            return true
        case .interrupted:
            operationTask?.cancel()
            operationTask = nil
            operation = .idle
            operationFailure = nil
            sessionState = .signedOut(profile: profile, compatibility: compatibility)
            return true
        case let .blocked(failure):
            // Reservation itself could not be made durable: preserve the genuinely
            // active operation — task, generation, epoch, and observable state —
            // exactly as it was, and surface a typed, retryable failure instead.
            operationFailure = .tokenStore(failure)
            return false
        }
    }

    /// Interrupts the in-flight sign-in or registration for the profile currently
    /// reflected in ``sessionState``, exactly as an explicit ``cancelAuthOperation()``
    /// does: attempts to durably reserve/enqueue a cleanup deletion for it (see
    /// ``AppModel/enqueueCancellationCleanup(for:globalEpoch:)``) and, only once that
    /// reservation actually succeeds, invalidates its credential epoch, so a save that
    /// has already passed its epoch recheck — or already durably applied — cannot
    /// survive the interruption.
    ///
    /// Returns ``AuthInterruptionOutcome/none`` if there was no in-flight
    /// sign-in/registration to interrupt (the caller must not proceed as though one
    /// existed); ``AuthInterruptionOutcome/interrupted(_:)`` with the interrupted
    /// profile's ID once the cleanup has been durably reserved; or
    /// ``AuthInterruptionOutcome/blocked(_:)`` when that reservation itself could not
    /// be made durable — in which case the caller must **not** proceed with whatever
    /// state transition (switching profile, retrying, returning to signed-out) it was
    /// about to make, since doing so would let an unprotected in-flight save be
    /// silently abandoned rather than durably cleaned up. Every caller
    /// (``cancelAuthOperation()``, ``selectProfile(_:)``, ``retry()``) must switch on
    /// every case explicitly rather than assuming success.
    ///
    /// Does not itself cancel ``operationTask`` or change
    /// ``selectedProfile``/``sessionState``: every caller does those on its own
    /// immediately afterward (only on ``AuthInterruptionOutcome/interrupted(_:)``),
    /// while `sessionState` still names the profile whose operation is being
    /// interrupted — this call must therefore always happen first, before any of
    /// that. Reservation (the durable ``markPending`` and its synchronous queue
    /// admission, both inside ``enqueueCancellationCleanup(for:globalEpoch:)``) is
    /// attempted *before* ``generation`` or the credential epoch are touched at all:
    /// on a mark failure (``CleanupReservation/markFailed(_:)``, surfaced to the
    /// caller as ``AuthInterruptionOutcome/blocked(_:)``), neither is mutated, so the
    /// genuinely active operation is left entirely intact rather than orphaned —
    /// bumped past its own ability to ever complete, yet not actually cleaned up
    /// either. Only on success does this advance ``generation`` and invalidate the
    /// credential epoch,
    /// unconditionally at that point (so a stale in-flight step can never mutate state
    /// once interrupted); every caller that proceeds past
    /// ``AuthInterruptionOutcome/interrupted(_:)`` separately advances ``generation``
    /// again afterward for its own unrelated reason (selecting a new profile,
    /// retrying, or explicit cancellation), which is harmless since ``isCurrent(_:)``
    /// only ever compares for exact equality against the latest value, never relies on
    /// a specific delta.
    @discardableResult
    func interruptActiveAuthOperationIfNeeded() -> AuthInterruptionOutcome {
        guard case let .signedOut(profile, _) = sessionState else { return .none }
        guard operation == .signingIn || operation == .registering else { return .none }
        switch enqueueCancellationCleanup(
            for: profile.id, globalEpoch: currentGlobalCredentialEpoch()
        ) {
        case .reserved:
            generation += 1
            invalidateCredentialEpoch(for: profile.id)
            return .interrupted(profile.id)
        case let .markFailed(failure):
            return .blocked(failure)
        }
    }

    /// Maps a thrown authentication step error to an operation failure, or `nil` for
    /// cancellation (which must not become an error).
    private func authOperationFailure(from error: any Error) -> SessionOperationFailure? {
        if error is CancellationError || error is StaleCredentialEpochError {
            return nil
        }
        if let authError = error as? AuthenticationError {
            return .authentication(authError)
        }
        return .authentication(.transportFailure("Unexpected authentication failure."))
    }
}

/// The outcome of ``AppModel/interruptActiveAuthOperationIfNeeded()``. See that
/// method's documentation for the exact obligations each case places on its caller.
enum AuthInterruptionOutcome {
    /// There was no in-flight sign-in/registration to interrupt.
    case none
    /// The interruption's cleanup was durably reserved; the caller may proceed with
    /// its own state transition.
    case interrupted(UUID)
    /// The cleanup this interruption depends on could not be durably reserved. The
    /// caller must preserve its prior state and surface this typed failure rather
    /// than proceeding as though an in-flight save were now safely guarded.
    case blocked(TokenStoreFailure)
}

/// Sign-out: deletes the selected profile's token before exposing signed-out.
extension AppModel {
    /// Deletes the selected profile's token before exposing signed-out.
    ///
    /// Only valid from ``SessionState/signedIn(profile:compatibility:user:)``. If token
    /// deletion fails, the session remains signed in and the failure is exposed via
    /// ``operationFailure``.
    func signOut() {
        guard case let .signedIn(profile, compatibility, _) = sessionState else { return }
        guard operation == .idle else { return }
        operationTask?.cancel()
        generation += 1
        let currentGeneration = generation
        let currentEpoch = currentCredentialEpoch(for: profile.id)
        let currentGlobalEpoch = currentGlobalCredentialEpoch()
        operation = .signingOut
        operationFailure = nil
        operationTask = Task { [weak self] in
            await self?.performSignOut(
                profile: profile,
                compatibility: compatibility,
                generation: currentGeneration,
                credentialEpoch: currentEpoch,
                globalEpoch: currentGlobalEpoch
            )
        }
    }

    func performSignOut(
        profile: ServerProfile,
        compatibility: ServerCompatibility,
        generation: Int,
        credentialEpoch: Int,
        globalEpoch: Int
    ) async {
        // The operation task may not start until after a profile switch has already
        // cancelled and superseded it. Reject that stale task before it can enqueue a
        // deletion behind newer same-profile token work.
        guard isCurrent(generation) else { return }

        do {
            // Serialized (see ``AppModel/serializedTokenAccess(for:epoch:globalEpoch:_:)``)
            // so a stale delete that is already in flight when superseded cannot race
            // with, or be raced by, a later read/save/delete for the same profile.
            try await serializedTokenAccess(
                for: profile.id, epoch: credentialEpoch, globalEpoch: globalEpoch
            ) { [tokenStore] in
                try await tokenStore.deleteToken(for: profile.id)
            }
        } catch {
            guard isCurrent(generation) else { return }
            operation = .idle
            operationFailure = (error is CancellationError || error is StaleCredentialEpochError)
                ? nil
                : .tokenStore(tokenStoreFailure(from: error))
            return
        }
        guard isCurrent(generation) else { return }
        operation = .idle
        operationFailure = nil
        sessionState = .signedOut(profile: profile, compatibility: compatibility)
    }
}
