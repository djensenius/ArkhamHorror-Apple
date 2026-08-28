import Foundation

/// Async continuations for ``AppModel``'s custom server profile management (see
/// `AppModel+ProfileManagement.swift`): the security-critical edit and removal
/// completions that must reconcile a profile's token with its (possibly changed)
/// endpoint, plus the small comparison/state-replacement helpers they rely on.
extension AppModel {
    // MARK: - Async continuations

    func performProfileUpdate(
        original: ServerProfile,
        updated: ServerProfile,
        endpointChanged: Bool,
        credentialEpoch: Int?,
        operationGeneration: Int
    ) async {
        defer {
            if isCurrentProfileOperation(operationGeneration) {
                profileManagementOperation = .idle
            }
        }

        if endpointChanged {
            guard let credentialEpoch else {
                profileManagementFailure = .storage(.unexpected)
                return
            }
            let deleted = await deleteTokenForEndpointChange(
                original, credentialEpoch: credentialEpoch, operationGeneration: operationGeneration
            )
            guard deleted else { return }
        }
        guard isCurrentProfileOperation(operationGeneration) else { return }

        var updatedProfiles = profiles
        guard let index = updatedProfiles.firstIndex(where: { $0.id == original.id }) else {
            profileManagementFailure = .profileNotFound
            return
        }
        updatedProfiles[index] = updated

        guard runProfileStorageVoid(generation: generation, {
            try profileStore.saveProfiles(updatedProfiles)
        }) else {
            // The token (if the endpoint changed) is already durably deleted at this
            // point; persistence itself failing is surfaced distinctly rather than
            // silently activating a half-applied edit.
            return
        }
        guard isCurrentProfileOperation(operationGeneration) else { return }
        profiles = updatedProfiles

        guard selectedProfile.id == original.id else { return }
        selectedProfile = updated
        if endpointChanged {
            flowTask?.cancel()
            operationTask?.cancel()
            operationTask = nil
            operation = .idle
            operationFailure = nil
            generation += 1
            restartFlow(for: updated, generation: generation)
        } else {
            sessionState = replacingProfile(in: sessionState, with: updated)
        }
    }

    /// Deletes `original`'s token as the precondition for activating/persisting an
    /// endpoint-changing edit. Returns `false` (having already surfaced a typed failure,
    /// unless the deletion was cancelled or superseded) when the caller must not
    /// proceed with the edit.
    private func deleteTokenForEndpointChange(
        _ original: ServerProfile, credentialEpoch: Int, operationGeneration: Int
    ) async -> Bool {
        do {
            // Serialized (see ``AppModel/serializedTokenAccess(for:epoch:_:)``) so this
            // delete is ordered against any other in-flight read/save/delete for the
            // same profile ID rather than racing them, and so a subsequent read for
            // this profile (e.g. a restarted flow) always observes the token as gone
            // before the edited endpoint can be activated. The credential epoch was
            // already invalidated synchronously before this delete was enqueued, so any
            // save/read for this profile captured under an earlier epoch — even one
            // already queued ahead of this delete — is rejected at the instant it would
            // otherwise touch the Keychain, rather than only being caught here.
            try await serializedTokenAccess(
                for: original.id, epoch: credentialEpoch
            ) { [tokenStore] in
                try await tokenStore.deleteToken(for: original.id)
            }
            return true
        } catch {
            guard isCurrentProfileOperation(operationGeneration) else { return false }
            guard !(error is CancellationError || error is StaleCredentialEpochError) else {
                return false
            }
            // Deletion failed: preserve the old profile/configuration untouched and
            // surface a typed, actionable failure rather than persisting an endpoint
            // change that could otherwise let the old token reach it.
            profileManagementFailure = .tokenStore(tokenStoreFailure(from: error))
            return false
        }
    }

    func performProfileRemoval(
        _ profile: ServerProfile, credentialEpoch: Int, operationGeneration: Int
    ) async {
        defer {
            if isCurrentProfileOperation(operationGeneration) {
                profileManagementOperation = .idle
            }
        }

        do {
            // Serialized (see ``AppModel/serializedTokenAccess(for:epoch:_:)``) so this
            // delete cannot race an in-flight save/read/delete for the same profile,
            // and the epoch — already invalidated synchronously before this delete was
            // enqueued — guarantees any such save/read captured earlier is rejected
            // rather than resurrecting a token for a profile being removed.
            try await serializedTokenAccess(
                for: profile.id, epoch: credentialEpoch
            ) { [tokenStore] in
                try await tokenStore.deleteToken(for: profile.id)
            }
        } catch {
            guard isCurrentProfileOperation(operationGeneration) else { return }
            guard !(error is CancellationError || error is StaleCredentialEpochError) else {
                return
            }
            // Deletion failed: preserve the profile rather than removing metadata for
            // a token that may still exist.
            profileManagementFailure = .tokenStore(tokenStoreFailure(from: error))
            return
        }
        guard isCurrentProfileOperation(operationGeneration) else { return }

        var updatedProfiles = profiles
        updatedProfiles.removeAll { $0.id == profile.id }

        guard runProfileStorageVoid(generation: generation, {
            try profileStore.saveProfiles(updatedProfiles)
        }) else { return }
        guard isCurrentProfileOperation(operationGeneration) else { return }
        profiles = updatedProfiles

        if selectedProfile.id == profile.id {
            // Coherently fall back to hosted and restart the flow, exactly as an
            // explicit user-initiated profile switch would.
            selectProfile(.hosted)
        }
    }

    // MARK: - Helpers

    /// Whether `lhs` and `rhs` resolve to the same normalized server endpoint
    /// (identical base URL), regardless of display name or identifier.
    ///
    /// Compares the already-canonicalized ``ServerProfile/baseURL`` directly rather
    /// than lowercasing the whole absolute string: ``ServerProfile`` validation already
    /// normalizes scheme and host to lowercase, so a direct comparison of the
    /// canonical form is scheme/host-case-insensitive by construction while still
    /// comparing the path exactly as written. A whole-string lowercase comparison
    /// would instead treat two servers whose paths differ only by case (for example
    /// `/TenantA` and `/tenanta`) as the same endpoint, which could route a token
    /// issued for one tenant's path to another.
    func isSameEndpoint(_ lhs: ServerProfile, _ rhs: ServerProfile) -> Bool {
        lhs.baseURL == rhs.baseURL
    }

    /// Returns `state` with its embedded ``ServerProfile`` replaced by `updated` when
    /// `state` carries a profile matching `updated.id`; otherwise returns `state`
    /// unchanged. Used to reflect a display-name-only edit of the currently active
    /// profile without re-probing or disturbing any other associated state.
    private func replacingProfile(
        in state: SessionState, with updated: ServerProfile
    ) -> SessionState {
        switch state {
        case let .checkingCompatibility(profile) where profile.id == updated.id:
            .checkingCompatibility(profile: updated)
        case let .signedOut(profile, compatibility) where profile.id == updated.id:
            .signedOut(profile: updated, compatibility: compatibility)
        case let .incompatible(profile, reason) where profile.id == updated.id:
            .incompatible(profile: updated, reason: reason)
        case let .unavailable(profile, reason) where profile.id == updated.id:
            .unavailable(profile: updated, reason: reason)
        case let .signedIn(profile, compatibility, user) where profile.id == updated.id:
            .signedIn(profile: updated, compatibility: compatibility, user: user)
        default:
            state
        }
    }
}
