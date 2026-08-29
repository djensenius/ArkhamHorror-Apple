import Foundation

/// Sign-out: deletes the selected profile's token before exposing signed-out.
///
/// Split out of ``AppModel+Authentication.swift`` purely by file size; every member
/// here operates on exactly the same `@MainActor`-isolated state declared/documented
/// there and in `AppModel.swift`.
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
