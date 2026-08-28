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
/// ``AppModel/serializedTokenAccess(for:epoch:_:)``). If that deletion fails, the old profile
/// and its token are left exactly as they were and a typed failure is surfaced — the
/// coordinator never sends a token for one origin to a newly edited endpoint, and it
/// never invents a plaintext or in-memory fallback for a token store it cannot durably
/// mutate. A display-name-only edit (no base URL change) never touches the token.
extension AppModel {
    /// Persists a profile-management mutation (add/edit/remove), surfacing any
    /// failure as a local ``ProfileManagementFailure/storage(_:)`` rather than the
    /// app-wide ``SessionState/storageCorrupted(_:)`` recovery flow.
    ///
    /// A profile add/edit/remove save failing (for example, a transient write
    /// error) does not mean the *existing* stored profiles/tokens are unreadable or
    /// corrupted, so it must not force every window into the destructive
    /// storage-reset presentation the way a genuine load-time corruption does (see
    /// ``AppModel/runStorageVoid(generation:_:)``, still used by
    /// ``confirmStorageReset()``'s reseed, where that *is* the right behavior).
    /// Returns `true` on success; on failure, returns `false` having already set
    /// `profileManagementFailure` unless `generation` is no longer current.
    func runProfileStorageVoid(generation: Int, _ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            guard isCurrent(generation) else { return false }
            profileManagementFailure = .storage(storageFailure(from: error))
            return false
        }
    }

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
        guard runProfileStorageVoid(generation: generation, {
            try profileStore.saveProfiles(updatedProfiles)
        }) else { return }
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
        // Invalidated synchronously, here, *before* the endpoint-changing delete is
        // even enqueued — not inside the async continuation below — so that every
        // token-store operation for this profile already in flight (or enqueued but
        // not yet run), captured under any epoch prior to this call, is guaranteed to
        // observe a mismatch when its turn in the queue actually arrives. The freshly
        // bumped value is captured immediately (nothing else can run between the bump
        // and this capture, since both are synchronous on the main actor), so this
        // edit's own delete below always matches its own invalidation.
        let credentialEpoch = endpointChanged ? invalidateCredentialEpoch(for: profile.id) : nil
        let globalEpoch = currentGlobalCredentialEpoch()
        profileManagementOperation = .saving(profile.id)
        profileManagementGeneration += 1
        let operationGeneration = profileManagementGeneration
        profileManagementTask?.cancel()
        profileManagementTask = Task { [weak self] in
            await self?.performProfileUpdate(
                original: profile,
                updated: updated,
                endpointChanged: endpointChanged,
                epochContext: ProfileUpdateEpochContext(
                    credentialEpoch: credentialEpoch,
                    globalEpoch: globalEpoch,
                    operationGeneration: operationGeneration
                )
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

        // Invalidated synchronously, before the removal delete is even enqueued. See
        // the matching comment in ``updateCustomProfile(_:displayName:rawURL:)``.
        let credentialEpoch = invalidateCredentialEpoch(for: profile.id)
        let globalEpoch = currentGlobalCredentialEpoch()
        profileManagementOperation = .removing(profile.id)
        profileManagementGeneration += 1
        let operationGeneration = profileManagementGeneration
        profileManagementTask?.cancel()
        profileManagementTask = Task { [weak self] in
            await self?.performProfileRemoval(
                profile,
                credentialEpoch: credentialEpoch,
                globalEpoch: globalEpoch,
                operationGeneration: operationGeneration
            )
        }
    }

    /// Explicitly, and only from ``SessionState/storageCorrupted(_:)``, securely
    /// deletes every stored token before discarding the unreadable profile/selection
    /// storage, reseeds only the canonical hosted profile, persists that reset, and
    /// restarts the launch flow.
    ///
    /// Never called implicitly: presentation code must obtain explicit user
    /// confirmation (e.g. a destructive confirmation alert) before invoking this, since
    /// corrupted storage is otherwise surfaced rather than silently erased.
    ///
    /// By the time storage is genuinely corrupted (as opposed to selection-only
    /// corruption, which ``AppModel/loadProfilesAndSelect(generation:)`` already
    /// repairs without ever reaching this state), the previously known profile IDs can
    /// no longer be trusted enough to delete their tokens individually, so this uses
    /// ``TokenStore/deleteAllTokens()`` — scoped only to this store's own
    /// service/namespace — instead. Credential cleanup must succeed before the old
    /// metadata is irreversibly replaced: `errSecItemNotFound` (nothing to delete) is
    /// success, but any other failure preserves the old stored state untouched and
    /// surfaces a typed, actionable failure rather than orphaning tokens whose owning
    /// profile metadata has just been erased.
    func confirmStorageReset() {
        guard case .storageCorrupted = sessionState else { return }
        guard profileManagementOperation == .idle else { return }
        flowTask?.cancel()
        operationTask?.cancel()
        profileManagementTask?.cancel()
        generation += 1
        let currentGeneration = generation
        profileManagementFailure = nil
        profileManagementOperation = .resettingStorage
        profileManagementGeneration += 1
        let operationGeneration = profileManagementGeneration

        // The service-wide credential epoch is bumped, and every per-profile queue
        // tail currently in flight is snapshotted, synchronously here — *before* the
        // barrier below is installed — so that:
        //   - every token operation already enqueued anywhere, captured under any
        //     earlier global epoch, is guaranteed to observe a mismatch at its
        //     recheck (which can only run after the snapshotted tails it is chained
        //     behind complete, and after the barrier this method installs resolves);
        //   - every new token operation that starts after this method returns
        //     observes the freshly installed barrier (`serviceResetBarrier`) and
        //     waits behind it, rather than racing `deleteAllTokens()` below.
        // The barrier task itself awaits exactly the snapshotted tails (never a new
        // operation's own tail, which instead awaits the barrier) before running the
        // wipe, so no self-wait/deadlock is possible.
        globalCredentialEpoch += 1
        let pendingTails = tokenAccessQueues.values.map(\.task)

        let barrierID = UUID()
        let barrierTask = Task<Void, Never> { [weak self] in
            for tail in pendingTails {
                await tail.value
            }
            guard let self else { return }
            await performStorageReset(
                generation: currentGeneration, operationGeneration: operationGeneration
            )
            if serviceResetBarrier?.id == barrierID {
                serviceResetBarrier = nil
            }
        }
        serviceResetBarrier = ServiceResetBarrier(id: barrierID, task: barrierTask)
        profileManagementTask = barrierTask
    }

    private func performStorageReset(generation: Int, operationGeneration: Int) async {
        defer {
            if isCurrentProfileOperation(operationGeneration) {
                profileManagementOperation = .idle
            }
        }

        do {
            try await tokenStore.deleteAllTokens()
        } catch {
            guard isCurrentProfileOperation(operationGeneration) else { return }
            guard !(error is CancellationError) else { return }
            // Cleanup failed: preserve the old (corrupted) stored state untouched
            // rather than replacing metadata while tokens may still exist under it.
            profileManagementFailure = .tokenStore(tokenStoreFailure(from: error))
            return
        }
        guard isCurrentProfileOperation(operationGeneration) else { return }
        guard isCurrent(generation) else { return }

        let resetProfiles = [ServerProfile.hosted]
        guard runStorageVoid(generation: generation, {
            try profileStore.saveProfiles(resetProfiles)
        }) else { return }
        guard runStorageVoid(generation: generation, {
            try profileStore.saveSelectedProfileID(ServerProfile.hosted.id)
        }) else { return }
        guard isCurrent(generation) else { return }

        profiles = resetProfiles
        selectedProfile = .hosted
        operation = .idle
        operationFailure = nil
        // Every profile this reset wiped tokens for is gone from `profiles` now; any
        // failure recorded against one of their IDs can never again be consulted by
        // ``beginAuthOperation(_:issueToken:)`` or
        // ``restoreToken(profile:compatibility:generation:)``, so it is cleared here
        // purely for hygiene rather than correctness.
        cancellationCleanupFailures.removeAll()
        restartFlow(for: .hosted, generation: generation)
    }
}
