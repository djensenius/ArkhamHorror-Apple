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
        epochContext: ProfileUpdateEpochContext
    ) async {
        let operationGeneration = epochContext.operationGeneration
        defer {
            if isCurrentProfileOperation(operationGeneration) {
                profileManagementOperation = .idle
            }
        }

        guard await awaitEndpointChangeCleanup(
            endpointChanged: endpointChanged,
            cleanupTask: epochContext.cleanupTask,
            operationGeneration: operationGeneration
        ) else { return }
        guard isCurrentProfileOperation(operationGeneration) else { return }

        var updatedProfiles = profiles
        guard let index = updatedProfiles.firstIndex(where: { $0.id == original.id }) else {
            profileManagementFailure = .profileNotFound
            return
        }
        // Rechecked here, at the serialized commit boundary, immediately before the
        // write: `original` was already verified to match the then-current stored
        // profile synchronously in `updateCustomProfile`, before either the cleanup
        // reservation above or this continuation's own suspension at
        // `awaitEndpointChangeCleanup` occurred. Today, `profileManagementOperation`
        // serializes every add/edit/remove so nothing else can have mutated this
        // profile in between — but this recheck makes that invariant load-bearing
        // rather than assumed, so this can never persist over a profile that changed
        // during any suspension this function awaits, now or in the future.
        guard updatedProfiles[index] == original else {
            profileManagementFailure = .editConflict
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

    /// Awaits the reservation's cleanup task (if any) for an endpoint-changing edit,
    /// returning `true` once it is safe for
    /// ``performProfileUpdate(original:updated:endpointChanged:epochContext:)`` to
    /// proceed to persistence. Returns `false` after already having handled every
    /// rejected outcome — a missing task for an edit that requires one (a programming
    /// error), or a typed deletion/tombstone-clear failure, in which case a typed
    /// ``profileManagementFailure`` is set unless this operation was itself
    /// superseded in the meantime. A display-name-only edit needs no cleanup at all
    /// and always returns `true` immediately. Extracted purely to keep the caller
    /// within the project's cyclomatic-complexity lint limit.
    private func awaitEndpointChangeCleanup(
        endpointChanged: Bool,
        cleanupTask: Task<TokenStoreFailure?, Never>?,
        operationGeneration: Int
    ) async -> Bool {
        guard endpointChanged else { return true }
        guard let cleanupTask else {
            profileManagementFailure = .storage(.unexpected)
            return false
        }
        // Awaits the exact same durable mark-then-admit reservation an explicit auth
        // cancellation uses: `nil` means the delete succeeded and its tombstone was
        // cleared; a non-nil failure means either step could not complete, in which
        // case the tombstone remains pending and this edit must not proceed.
        guard let failure = await cleanupTask.value else { return true }
        guard isCurrentProfileOperation(operationGeneration) else { return false }
        // Deletion (or its required tombstone clear) failed: preserve the old
        // profile/configuration untouched and surface a typed, actionable failure
        // rather than persisting an endpoint change that could otherwise let the old
        // token reach it.
        profileManagementFailure = .tokenStore(failure)
        return false
    }

    func performProfileRemoval(
        _ profile: ServerProfile,
        cleanupTask: Task<TokenStoreFailure?, Never>,
        operationGeneration: Int
    ) async {
        defer {
            if isCurrentProfileOperation(operationGeneration) {
                profileManagementOperation = .idle
            }
        }

        // Awaits the exact same durable mark-then-admit reservation an explicit auth
        // cancellation uses; see the matching comment in `performProfileUpdate`.
        if let failure = await cleanupTask.value {
            guard isCurrentProfileOperation(operationGeneration) else { return }
            // Deletion (or its required tombstone clear) failed: preserve the profile
            // rather than removing metadata for a token that may still exist.
            profileManagementFailure = .tokenStore(failure)
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
            // Any active sign-in/registration for this profile was already
            // interrupted synchronously, as part of the same reservation that
            // protected its token (``reserveCleanupInterruptingActiveAuth(for:)``, in
            // ``removeCustomProfile(_:)``, before this async continuation ever ran) —
            // this must not call the public ``selectProfile(_:)`` (which would attempt
            // a second, independent, and now-redundant cleanup reservation for a
            // profile ID whose metadata has already been persisted as removed), only
            // its persist-then-restart tail.
            activateHostedProfileAfterRemoval()
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
