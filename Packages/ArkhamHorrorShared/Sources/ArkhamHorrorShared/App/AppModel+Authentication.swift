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
        // Captured once, here, alongside `generation` — not re-read right before the
        // save — so that an endpoint edit/removal which bumps this profile's epoch at
        // any point after this operation started (even while this operation's save is
        // already queued behind that edit/removal's delete) is guaranteed to leave this
        // capture stale. See `AppModel/serializedTokenAccess(for:epoch:_:)`.
        let currentEpoch = currentCredentialEpoch(for: profile.id)
        operation = operationKind
        operationFailure = nil
        operationTask = Task { [weak self] in
            await self?.performAuthOperation(
                profile: profile,
                compatibility: compatibility,
                generation: currentGeneration,
                credentialEpoch: currentEpoch,
                issueToken: issueToken
            )
        }
    }

    /// Authenticates or registers, validates the returned token via `whoami`, and only
    /// then durably saves it. Signed-in is never exposed unless the save succeeds.
    func performAuthOperation(
        profile: ServerProfile,
        compatibility: ServerCompatibility,
        generation: Int,
        credentialEpoch: Int,
        issueToken: @Sendable (ServerProfile) async throws -> AuthToken
    ) async {
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
                for: profile.id, epoch: credentialEpoch
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
    /// passed those checks and is queued in ``serializedTokenAccess(for:epoch:_:)`` is
    /// skipped rather than durably saving a token after the user has cancelled).
    ///
    /// Valid only while ``operation`` is ``SessionOperation/signingIn`` or
    /// ``SessionOperation/registering`` from ``SessionState/signedOut(profile:compatibility:)``;
    /// otherwise a no-op, so redundant calls (e.g. a Cancel button tap racing a
    /// just-completed sign-in, or an idempotent view-disappearance callback after
    /// successful navigation) are always safe.
    func cancelAuthOperation() {
        guard case let .signedOut(profile, compatibility) = sessionState else { return }
        guard operation == .signingIn || operation == .registering else { return }
        operationTask?.cancel()
        operationTask = nil
        generation += 1
        invalidateCredentialEpoch(for: profile.id)
        operation = .idle
        operationFailure = nil
        sessionState = .signedOut(profile: profile, compatibility: compatibility)
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
        operation = .signingOut
        operationFailure = nil
        operationTask = Task { [weak self] in
            await self?.performSignOut(
                profile: profile,
                compatibility: compatibility,
                generation: currentGeneration,
                credentialEpoch: currentEpoch
            )
        }
    }

    func performSignOut(
        profile: ServerProfile,
        compatibility: ServerCompatibility,
        generation: Int,
        credentialEpoch: Int
    ) async {
        // The operation task may not start until after a profile switch has already
        // cancelled and superseded it. Reject that stale task before it can enqueue a
        // deletion behind newer same-profile token work.
        guard isCurrent(generation) else { return }

        do {
            // Serialized (see ``AppModel/serializedTokenAccess(for:epoch:_:)``) so a
            // stale delete that is already in flight when superseded cannot race with,
            // or be raced by, a later read/save/delete for the same profile.
            try await serializedTokenAccess(
                for: profile.id, epoch: credentialEpoch
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
