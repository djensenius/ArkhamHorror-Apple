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
    /// durably saving a token after the user has cancelled).
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
    func cancelAuthOperation() {
        guard case let .signedOut(profile, compatibility) = sessionState else { return }
        guard operation == .signingIn || operation == .registering else { return }
        operationTask?.cancel()
        operationTask = nil
        interruptActiveAuthOperationIfNeeded()
        operation = .idle
        operationFailure = nil
        sessionState = .signedOut(profile: profile, compatibility: compatibility)
    }

    /// Interrupts the in-flight sign-in or registration for the profile currently
    /// reflected in ``sessionState``, exactly as an explicit ``cancelAuthOperation()``
    /// does: invalidates its credential epoch and durably reserves/enqueues a cleanup
    /// deletion for it (see ``AppModel/enqueueCancellationCleanup(for:globalEpoch:)``),
    /// so a save that has already passed its epoch recheck — or already durably
    /// applied — cannot survive the interruption. Returns the interrupted profile's
    /// ID, or `nil` if there was no in-flight sign-in/registration to interrupt (in
    /// which case the caller must not proceed as though one existed).
    ///
    /// Does not itself cancel ``operationTask`` or change
    /// ``selectedProfile``/``sessionState``: every caller (``cancelAuthOperation()``,
    /// ``selectProfile(_:)``, ``retry()``) does those on its own immediately
    /// afterward, while `sessionState` still names the profile whose operation is
    /// being interrupted — this call must therefore always happen first, before any
    /// of that. It *does* advance ``generation`` itself (so a stale in-flight step
    /// cannot mutate state once interrupted); every caller separately advances it
    /// again afterward for its own unrelated reason (selecting a new profile,
    /// retrying, or explicit cancellation), which is harmless since
    /// ``isCurrent(_:)`` only ever compares for exact equality against the latest
    /// value, never relies on a specific delta.
    @discardableResult
    func interruptActiveAuthOperationIfNeeded() -> UUID? {
        guard case let .signedOut(profile, _) = sessionState else { return nil }
        guard operation == .signingIn || operation == .registering else { return nil }
        generation += 1
        invalidateCredentialEpoch(for: profile.id)
        enqueueCancellationCleanup(for: profile.id, globalEpoch: currentGlobalCredentialEpoch())
        return profile.id
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
