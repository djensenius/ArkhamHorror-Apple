import Foundation

/// Custom server profile management: add, edit, and remove, plus explicit,
/// user-confirmed recovery from corrupted profile storage.
///
/// Every mutation reuses ``ServerProfile/custom(id:displayName:rawURL:)`` for URL and
/// display-name validation rather than duplicating any parsing; this file only adds the
/// cross-profile checks (duplicate identifiers/endpoints) and the hosted/custom/token
/// invariants that a single profile's validator cannot know about on its own.
///
/// Security invariant: an edit that changes a profile's normalized base URL — and a
/// removal — deletes that profile's existing token *before* the new endpoint is
/// activated/persisted (or the profile removed), through the exact same durable
/// mark-then-admit reservation an explicit auth cancellation uses (see
/// ``AppModel/enqueueCancellationCleanup(for:globalEpoch:)``): a crash-durable
/// tombstone is written before the delete is even attempted, and both the mark and the
/// delete/tombstone-clear must succeed before the edit/removal is allowed to proceed.
/// If the mark itself cannot be made durable, nothing else is mutated at all — the
/// profile, its token, and every generation/epoch counter are left exactly as they
/// were. If the deletion (or clearing its tombstone) fails, the old profile and its
/// token are likewise left exactly as they were and a typed failure is surfaced — the
/// coordinator never sends a token for one origin to a newly edited endpoint, and it
/// never invents a plaintext or in-memory fallback for a token store it cannot durably
/// mutate. A display-name-only edit (no base URL change) never touches
/// the token.
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
    ///
    /// Returns a fresh submission identity (recorded in ``currentProfileSubmissionID``)
    /// once this edit is actually started, or `nil` if it was rejected synchronously
    /// (invalid kind/profile, a concurrent operation already in flight, validation
    /// failure, a mark failure, or a stale opening snapshot). A caller such as
    /// ``ServerProfileEditorView`` should remember this and compare it against
    /// ``currentProfileSubmissionID`` before treating a later
    /// ``profileManagementOperation`` transition to `.idle` as *its own* completion:
    /// two windows editing the same profile ID would otherwise both recognize a
    /// `.saving(profileID) -> .idle` transition as "my save finished," even when only
    /// one of them actually submitted.
    ///
    /// `profile` doubles as this edit's optimistic-concurrency expectation: it is the
    /// exact, immutable snapshot the caller opened its editor with. If another window
    /// already changed this same profile (name and/or endpoint) since then, `profile`
    /// no longer matches the currently saved entry with its ID, and this call is
    /// rejected synchronously with ``ProfileManagementFailure/editConflict`` — leaving
    /// every profile, token, generation, and epoch exactly as they were, and the
    /// caller's own unsaved fields untouched — rather than silently computing
    /// `endpointChanged` from stale data and overwriting whatever the other window
    /// just saved.
    @discardableResult
    func updateCustomProfile(
        _ profile: ServerProfile, displayName: String, rawURL: String
    ) -> UUID? {
        guard profile.kind == .custom else {
            profileManagementFailure = .cannotModifyHosted
            return nil
        }
        guard let currentIndex = profiles.firstIndex(where: { $0.id == profile.id }) else {
            profileManagementFailure = .profileNotFound
            return nil
        }
        guard profiles[currentIndex] == profile else {
            profileManagementFailure = .editConflict
            return nil
        }
        guard profileManagementOperation == .idle else { return nil }
        guard let updated = validatedCustomProfileEdit(
            profile, displayName: displayName, rawURL: rawURL
        ) else { return nil }

        let endpointChanged = !isSameEndpoint(profile, updated)
        // For an endpoint-changing edit, ``reserveCleanupInterruptingActiveAuth(for:)``
        // must succeed *before* anything else is mutated here: on a mark failure, the
        // profile, its token, ``profileManagementOperation``/``profileManagementGeneration``,
        // the profile's credential epoch, and any active sign-in/registration for it
        // are all left exactly as they were, rather than half-applying the edit or
        // leaving an in-flight save for this profile able to reach the Keychain under
        // an epoch that was never actually invalidated. Only on success are the
        // credential epoch — and, if `profile` is exactly the one an active
        // sign-in/registration currently names, that operation itself — invalidated
        // synchronously, as part of that same reservation, so every token-store
        // operation for this profile already in flight (or enqueued but not yet run),
        // captured under any epoch prior to this call, is guaranteed to observe a
        // mismatch when its turn in the queue actually arrives, and a stuck auth
        // operation is never left running past the endpoint it was authenticating
        // against.
        var cleanupTask: Task<TokenStoreFailure?, Never>?
        if endpointChanged {
            switch reserveCleanupInterruptingActiveAuth(for: profile) {
            case let .reserved(task):
                cleanupTask = task
            case let .markFailed(failure):
                profileManagementFailure = .tokenStore(failure)
                return nil
            }
        }
        let submissionID = UUID()
        currentProfileSubmissionID = submissionID
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
                    cleanupTask: cleanupTask,
                    operationGeneration: operationGeneration
                )
            )
        }
        return submissionID
    }

    /// Validates `profile`'s edit in isolation from
    /// ``updateCustomProfile(_:displayName:rawURL:)``'s cleanup-reservation/scheduling
    /// logic, purely to keep that function within the project's function-length lint
    /// limit. The kind/existence/idle checks already happened in the caller; this
    /// only parses/validates the new endpoint and checks for a duplicate. Sets a
    /// typed ``profileManagementFailure`` and returns `nil` for every rejected edit;
    /// returns the validated replacement profile otherwise.
    private func validatedCustomProfileEdit(
        _ profile: ServerProfile, displayName: String, rawURL: String
    ) -> ServerProfile? {
        profileManagementFailure = nil

        let updated: ServerProfile
        do {
            updated = try ServerProfile.custom(
                id: profile.id, displayName: displayName, rawURL: rawURL
            )
        } catch let error as ServerProfileError {
            profileManagementFailure = .invalidProfile(error)
            return nil
        } catch {
            profileManagementFailure = .invalidProfile(.malformedURL)
            return nil
        }

        guard !profiles.contains(where: { $0.id != profile.id && isSameEndpoint($0, updated) })
        else {
            profileManagementFailure = .duplicateEndpoint
            return nil
        }
        return updated
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

        // ``reserveCleanupInterruptingActiveAuth(for:)`` must succeed before anything
        // else is mutated here — see the matching comment in
        // ``updateCustomProfile(_:displayName:rawURL:)``. On a mark failure, the
        // profile, its `profileManagementOperation`/`profileManagementGeneration`/
        // credential epoch, and any active sign-in/registration for it are all left
        // exactly as they were. On success, that same reservation both invalidates
        // the profile's credential epoch and — if `profile` is exactly the one an
        // active sign-in/registration currently names — interrupts that operation,
        // so no second, independent reservation is ever needed (or attempted) after
        // this profile's metadata is removed; see
        // ``AppModel/activateHostedProfileAfterRemoval()`` below, used instead of the
        // public ``selectProfile(_:)`` for exactly this reason.
        let cleanupTask: Task<TokenStoreFailure?, Never>
        switch reserveCleanupInterruptingActiveAuth(for: profile) {
        case let .reserved(task):
            cleanupTask = task
        case let .markFailed(failure):
            profileManagementFailure = .tokenStore(failure)
            return
        }
        profileManagementOperation = .removing(profile.id)
        profileManagementGeneration += 1
        let operationGeneration = profileManagementGeneration
        profileManagementTask?.cancel()
        profileManagementTask = Task { [weak self] in
            await self?.performProfileRemoval(
                profile,
                cleanupTask: cleanupTask,
                operationGeneration: operationGeneration
            )
        }
    }
}
