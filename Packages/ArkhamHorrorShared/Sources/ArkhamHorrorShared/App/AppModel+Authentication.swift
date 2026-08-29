import Foundation

/// Sign-in and registration: authenticate or register, validate the returned token via
/// `whoami`, and only then durably save it. Signed-in is never exposed unless the save
/// succeeds, and credentials/registration details are never stored on `self`.
extension AppModel {
    /// Authenticates with `credentials` on the currently selected (usable) server.
    ///
    /// Only valid from ``SessionState/signedOut(profile:compatibility:)``. `credentials`
    /// is passed through to the injected session and never stored on `self`. Returns
    /// the new attempt's identity (see ``currentAuthAttemptID``) for the caller to
    /// remember and later present to ``cancelAuthOperation(ownedBy:)``, or `nil` if no
    /// operation could be started (already busy, or not signed out).
    @discardableResult
    func signIn(_ credentials: AuthenticationCredentials) -> UUID? {
        beginAuthOperation(.signingIn) { [authenticationSession] profile in
            try await authenticationSession.authenticate(credentials, on: profile)
        }
    }

    /// Registers a new account with `details` on the currently selected (usable) server.
    ///
    /// Only valid from ``SessionState/signedOut(profile:compatibility:)``. `details` is
    /// passed through to the injected session and never stored on `self`. Returns the
    /// new attempt's identity, exactly like ``signIn(_:)``.
    @discardableResult
    func register(_ details: RegistrationDetails) -> UUID? {
        beginAuthOperation(.registering) { [authenticationSession] profile in
            try await authenticationSession.register(details, on: profile)
        }
    }

    /// Starts a sign-in or registration, returning the fresh, unique identity of this
    /// attempt (recorded in ``currentAuthAttemptID``) for the caller to remember — see
    /// ``cancelAuthOperation(ownedBy:)``. Returns `nil` without starting anything if
    /// `sessionState` is not ``SessionState/signedOut(profile:compatibility:)`` or an
    /// operation is already in flight.
    @discardableResult
    func beginAuthOperation(
        _ operationKind: SessionOperation,
        issueToken: @escaping @Sendable (ServerProfile) async throws -> AuthToken
    ) -> UUID? {
        guard case let .signedOut(profile, compatibility) = sessionState else { return nil }
        guard operation == .idle else { return nil }
        operationTask?.cancel()
        generation += 1
        let currentGeneration = generation
        let currentGlobalEpoch = currentGlobalCredentialEpoch()
        let attemptID = UUID()
        currentAuthAttemptID = attemptID
        operation = operationKind
        operationFailure = nil
        authFailure = nil
        operationTask = Task { [weak self] in
            await self?.beginAuthOperationAfterResolvingCleanup(
                profile: profile,
                compatibility: compatibility,
                generation: currentGeneration,
                globalEpoch: currentGlobalEpoch,
                issueToken: issueToken
            )
        }
        return attemptID
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
            // A registry-wide enumeration failure has already transitioned
            // `sessionState` to `.credentialCleanupRegistryCorrupted`, session-wide;
            // this operation must still stop (credential use stays blocked), but
            // must not clobber that state with a narrower, merely-per-operation
            // failure presentation a plain retry could never actually repair.
            operation = .idle
            guard !isCredentialCleanupRegistryCorrupted else { return }
            recordAuthFailure(.tokenStore(failure))
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
            recordAuthFailure(authOperationFailure(from: error))
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
            recordAuthFailure(authOperationFailure(from: error))
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
            recordAuthFailure(
                (error is CancellationError || error is StaleCredentialEpochError)
                    ? nil
                    : .tokenStore(tokenStoreFailure(from: error))
            )
            return
        }

        guard isCurrent(generation) else { return }
        operation = .idle
        authFailure = nil
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
    /// ``SessionOperation/registering`` from ``SessionState/signedOut(profile:compatibility:)``
    /// **and** `attemptID` names that exact operation (see ``currentAuthAttemptID``);
    /// otherwise a no-op, so redundant calls (e.g. a Cancel button tap racing a
    /// just-completed sign-in, an idempotent view-disappearance callback after
    /// successful navigation, or a *different* window's form that never itself
    /// started the currently active operation — `AppModel` is shared process-wide
    /// across every window, so more than one sign-in/registration form can be open at
    /// once) are always safe. A successfully established session
    /// (``SessionState/signedIn(profile:compatibility:user:)``) can never be undone by
    /// this method, since by then ``operation`` is no longer ``signingIn``/``registering``.
    /// A caller whose own `attemptID` does not (or no longer) match the active
    /// operation must still treat a `true` return as "safe to dismiss my own form,"
    /// since it means there is either no active operation at all, or one this caller
    /// never started and so has no standing to interrupt — only that caller's own
    /// local presentation state (its sheet, its local password) is affected, never the
    /// unrelated operation itself.
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
    /// caller to worry about (there was none to begin with, `attemptID` did not name
    /// the active operation, or this call's own reservation succeeded and it has been
    /// cleanly interrupted) — safe for a caller such as ``SignInView``/``RegisterView``
    /// to treat as "cancellation is safe to dismiss for." Returns `false` only when
    /// `attemptID` *does* name the genuinely active operation and it could not be
    /// safely interrupted because its cleanup reservation failed
    /// (``AuthInterruptionOutcome/blocked(_:)``): the operation remains exactly as it
    /// was and the caller must **not** dismiss/navigate away, since doing so would
    /// abandon an unprotected in-flight save; ``authFailure`` is already set,
    /// attributed to this exact attempt, for the owning UI to surface.
    @discardableResult
    func cancelAuthOperation(ownedBy attemptID: UUID?) -> Bool {
        guard case let .signedOut(profile, compatibility) = sessionState else { return true }
        guard operation == .signingIn || operation == .registering else { return true }
        // Only the exact form/window that started the currently active attempt may
        // cancel it. A `nil` or stale `attemptID` — this caller never submitted, or
        // its own remembered attempt has already been superseded by an entirely new
        // one (which can only happen once the caller's own attempt has itself already
        // gone idle, at which point the guard above would already have returned
        // `true`) — must not interrupt an operation this caller has no standing over;
        // it is safe for the caller to dismiss its own presentation regardless.
        guard attemptID != nil, attemptID == currentAuthAttemptID else { return true }
        switch interruptActiveAuthOperationIfNeeded() {
        case .none:
            return true
        case .interrupted:
            operationTask?.cancel()
            operationTask = nil
            operation = .idle
            authFailure = nil
            sessionState = .signedOut(profile: profile, compatibility: compatibility)
            return true
        case let .blocked(failure):
            // Reservation itself could not be made durable: preserve the genuinely
            // active operation — task, generation, epoch, and observable state —
            // exactly as it was, and surface a typed, retryable failure instead,
            // attributed to the exact attempt this cancellation was requested for
            // (already proven above to equal ``currentAuthAttemptID``) so only the
            // owning form renders it.
            recordAuthFailure(.tokenStore(failure))
            return false
        }
    }

    /// Interrupts the in-flight sign-in or registration for the profile currently
    /// reflected in ``sessionState``, exactly as an explicit ``cancelAuthOperation(ownedBy:)``
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
    /// (``cancelAuthOperation(ownedBy:)``, ``selectProfile(_:)``, ``retry()``) must switch on
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

    /// Records `failure` (or clears any prior failure, when `nil`) as the currently
    /// active sign-in/registration attempt's own ``authFailure``, tagged with
    /// ``currentAuthAttemptID``.
    ///
    /// Every call site here runs only once its own captured `generation` has already
    /// been proven still current, and a new attempt cannot start (and so cannot
    /// overwrite ``currentAuthAttemptID``) until this one has itself reached
    /// ``SessionOperation/idle`` — so `currentAuthAttemptID` is guaranteed to still
    /// name exactly this attempt at every call site. Falls back to simply clearing
    /// ``authFailure`` if, defensively, no attempt ID were present at all (which
    /// should not be reachable given the above), rather than attributing a failure to
    /// no attempt at all.
    private func recordAuthFailure(_ failure: SessionOperationFailure?) {
        guard let attemptID = currentAuthAttemptID else {
            authFailure = nil
            return
        }
        authFailure = failure.map { AttemptScopedAuthFailure(attemptID: attemptID, failure: $0) }
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
