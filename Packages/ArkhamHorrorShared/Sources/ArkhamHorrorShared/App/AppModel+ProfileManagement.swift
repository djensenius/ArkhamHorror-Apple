import Foundation

/// Custom server profile management: add, edit, and remove, plus explicit,
/// user-confirmed recovery from corrupted profile storage.
///
/// Every mutation reuses ``ServerProfile/custom(id:displayName:rawURL:)`` for URL and
/// display-name validation rather than duplicating any parsing; this file only adds the
/// cross-profile checks (duplicate identifiers/endpoints) and the hosted/custom/token
/// invariants that a single profile's validator cannot know about on its own.
///
/// Security invariant: an edit that changes a profile's normalized base URL deletes that
/// profile's existing token *before* the new endpoint is activated or persisted, through
/// the same serialized token-access seam used by authentication (see
/// ``AppModel/serializedTokenAccess(for:_:)``). If that deletion fails, the old profile
/// and its token are left exactly as they were and a typed failure is surfaced — the
/// coordinator never sends a token for one origin to a newly edited endpoint, and it
/// never invents a plaintext or in-memory fallback for a token store it cannot durably
/// mutate. A display-name-only edit (no base URL change) never touches the token.
extension AppModel {
    /// Validates and appends a new custom server profile.
    ///
    /// Purely synchronous: a brand-new profile has no existing token to reconcile, so
    /// there is no async work to guard against staleness. Fails with
    /// ``ProfileManagementFailure/invalidProfile(_:)`` for any URL/name validation
    /// failure (reusing ``ServerProfile`` validation) or
    /// ``ProfileManagementFailure/duplicateEndpoint`` when another saved profile already
    /// resolves to the same normalized endpoint.
    func addCustomProfile(displayName: String, rawURL: String) {
        guard profileManagementOperation == .idle else { return }
        profileManagementFailure = nil

        let newProfile: ServerProfile
        do {
            newProfile = try ServerProfile.custom(displayName: displayName, rawURL: rawURL)
        } catch let error as ServerProfileError {
            profileManagementFailure = .invalidProfile(error)
            return
        } catch {
            profileManagementFailure = .invalidProfile(.malformedURL)
            return
        }

        guard !profiles.contains(where: { isSameEndpoint($0, newProfile) }) else {
            profileManagementFailure = .duplicateEndpoint
            return
        }

        let updatedProfiles = profiles + [newProfile]
        profileManagementOperation = .saving(newProfile.id)
        defer { profileManagementOperation = .idle }
        guard runStorageVoid(generation: generation, {
            try profileStore.saveProfiles(updatedProfiles)
        }) else {
            profileManagementFailure = .storage(.unexpected)
            return
        }
        profiles = updatedProfiles
    }

    /// Validates and applies an edit to an existing custom profile.
    ///
    /// `profile` must be a currently saved ``ServerProfileKind/custom`` profile; the
    /// canonical hosted profile is immutable (``ProfileManagementFailure/cannotModifyHosted``).
    /// When the normalized base URL is unchanged, this is a display-name-only edit that
    /// retains the profile's token untouched. When it changes, the existing token for
    /// `profile.id` is securely deleted before the new endpoint is persisted or (if
    /// `profile` is currently selected) activated.
    func updateCustomProfile(_ profile: ServerProfile, displayName: String, rawURL: String) {
        guard profile.kind == .custom else {
            profileManagementFailure = .cannotModifyHosted
            return
        }
        guard profiles.contains(where: { $0.id == profile.id }) else {
            profileManagementFailure = .profileNotFound
            return
        }
        guard profileManagementOperation == .idle else { return }
        profileManagementFailure = nil

        let updated: ServerProfile
        do {
            updated = try ServerProfile.custom(
                id: profile.id, displayName: displayName, rawURL: rawURL
            )
        } catch let error as ServerProfileError {
            profileManagementFailure = .invalidProfile(error)
            return
        } catch {
            profileManagementFailure = .invalidProfile(.malformedURL)
            return
        }

        guard !profiles.contains(where: { $0.id != profile.id && isSameEndpoint($0, updated) })
        else {
            profileManagementFailure = .duplicateEndpoint
            return
        }

        let endpointChanged = !isSameEndpoint(profile, updated)
        profileManagementOperation = .saving(profile.id)
        profileManagementGeneration += 1
        let operationGeneration = profileManagementGeneration
        profileManagementTask?.cancel()
        profileManagementTask = Task { [weak self] in
            await self?.performProfileUpdate(
                original: profile,
                updated: updated,
                endpointChanged: endpointChanged,
                operationGeneration: operationGeneration
            )
        }
    }

    /// Removes a custom profile, deleting its token first.
    ///
    /// `profile` must be a currently saved ``ServerProfileKind/custom`` profile; the
    /// canonical hosted profile cannot be removed
    /// (``ProfileManagementFailure/cannotModifyHosted``). If token deletion fails, the
    /// profile is preserved and a typed failure is surfaced rather than removing
    /// metadata for a token that may still exist. If the removed profile was selected,
    /// selection falls back to hosted and the launch flow restarts for it, exactly as
    /// ``AppModel/selectProfile(_:)`` already does.
    func removeCustomProfile(_ profile: ServerProfile) {
        guard profile.kind == .custom else {
            profileManagementFailure = .cannotModifyHosted
            return
        }
        guard profiles.contains(where: { $0.id == profile.id }) else {
            profileManagementFailure = .profileNotFound
            return
        }
        guard profileManagementOperation == .idle else { return }
        profileManagementFailure = nil

        profileManagementOperation = .removing(profile.id)
        profileManagementGeneration += 1
        let operationGeneration = profileManagementGeneration
        profileManagementTask?.cancel()
        profileManagementTask = Task { [weak self] in
            await self?.performProfileRemoval(profile, operationGeneration: operationGeneration)
        }
    }

    /// Explicitly, and only from ``SessionState/storageCorrupted(_:)``, discards the
    /// unreadable profile/selection storage, reseeds only the canonical hosted profile,
    /// persists that reset, and restarts the launch flow.
    ///
    /// Never called implicitly: presentation code must obtain explicit user
    /// confirmation (e.g. a destructive confirmation alert) before invoking this, since
    /// corrupted storage is otherwise surfaced rather than silently erased.
    func confirmStorageReset() {
        guard case .storageCorrupted = sessionState else { return }
        flowTask?.cancel()
        operationTask?.cancel()
        profileManagementTask?.cancel()
        generation += 1
        let currentGeneration = generation

        let resetProfiles = [ServerProfile.hosted]
        guard runStorageVoid(generation: currentGeneration, {
            try profileStore.saveProfiles(resetProfiles)
        }) else { return }
        guard runStorageVoid(generation: currentGeneration, {
            try profileStore.saveSelectedProfileID(ServerProfile.hosted.id)
        }) else { return }
        guard isCurrent(currentGeneration) else { return }

        profiles = resetProfiles
        selectedProfile = .hosted
        operation = .idle
        operationFailure = nil
        restartFlow(for: .hosted, generation: currentGeneration)
    }

    // MARK: - Async continuations

    func performProfileUpdate(
        original: ServerProfile,
        updated: ServerProfile,
        endpointChanged: Bool,
        operationGeneration: Int
    ) async {
        defer {
            if isCurrentProfileOperation(operationGeneration) {
                profileManagementOperation = .idle
            }
        }

        if endpointChanged {
            let deleted = await deleteTokenForEndpointChange(
                original, operationGeneration: operationGeneration
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

        guard runStorageVoid(generation: generation, {
            try profileStore.saveProfiles(updatedProfiles)
        }) else {
            // The token (if the endpoint changed) is already durably deleted at this
            // point; persistence itself failing is surfaced distinctly rather than
            // silently activating a half-applied edit.
            profileManagementFailure = .storage(.unexpected)
            return
        }
        guard isCurrentProfileOperation(operationGeneration) else { return }
        profiles = updatedProfiles

        guard selectedProfile.id == original.id else { return }
        selectedProfile = updated
        if endpointChanged {
            flowTask?.cancel()
            operationTask?.cancel()
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
        _ original: ServerProfile, operationGeneration: Int
    ) async -> Bool {
        do {
            // Serialized (see ``AppModel/serializedTokenAccess(for:_:)``) so this
            // delete is ordered against any other in-flight read/save/delete for the
            // same profile ID rather than racing them, and so a subsequent read for
            // this profile (e.g. a restarted flow) always observes the token as gone
            // before the edited endpoint can be activated.
            try await serializedTokenAccess(for: original.id) { [tokenStore] in
                try await tokenStore.deleteToken(for: original.id)
            }
            return true
        } catch {
            guard isCurrentProfileOperation(operationGeneration) else { return false }
            guard !(error is CancellationError) else { return false }
            // Deletion failed: preserve the old profile/configuration untouched and
            // surface a typed, actionable failure rather than persisting an endpoint
            // change that could otherwise let the old token reach it.
            profileManagementFailure = .tokenStore(tokenStoreFailure(from: error))
            return false
        }
    }

    func performProfileRemoval(_ profile: ServerProfile, operationGeneration: Int) async {
        defer {
            if isCurrentProfileOperation(operationGeneration) {
                profileManagementOperation = .idle
            }
        }

        do {
            // Serialized (see ``AppModel/serializedTokenAccess(for:_:)``) so this
            // delete cannot race an in-flight save/read/delete for the same profile.
            try await serializedTokenAccess(for: profile.id) { [tokenStore] in
                try await tokenStore.deleteToken(for: profile.id)
            }
        } catch {
            guard isCurrentProfileOperation(operationGeneration) else { return }
            guard !(error is CancellationError) else { return }
            // Deletion failed: preserve the profile rather than removing metadata for
            // a token that may still exist.
            profileManagementFailure = .tokenStore(tokenStoreFailure(from: error))
            return
        }
        guard isCurrentProfileOperation(operationGeneration) else { return }

        var updatedProfiles = profiles
        updatedProfiles.removeAll { $0.id == profile.id }

        guard runStorageVoid(generation: generation, {
            try profileStore.saveProfiles(updatedProfiles)
        }) else {
            profileManagementFailure = .storage(.unexpected)
            return
        }
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
    private func isSameEndpoint(_ lhs: ServerProfile, _ rhs: ServerProfile) -> Bool {
        lhs.baseURL.absoluteString.lowercased() == rhs.baseURL.absoluteString.lowercased()
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
