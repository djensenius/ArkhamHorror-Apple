import Foundation

/// Startup: loading persisted profiles, seeding the hosted profile, and restoring the
/// selected profile before handing off to compatibility/token restoration.
extension AppModel {
    func startLaunchFlow() {
        generation += 1
        let currentGeneration = generation
        flowTask = Task { [weak self] in
            await self?.loadProfilesAndSelect(generation: currentGeneration)
        }
    }

    /// Loads persisted profiles, seeds the hosted profile exactly once, restores the
    /// selected profile (falling back to hosted when absent or unknown), then begins
    /// the compatibility probe and token restoration for that profile.
    func loadProfilesAndSelect(generation: Int) async {
        guard let loadedProfiles = runStorage(generation: generation, {
            try profileStore.loadProfiles()
        }) else { return }

        var resolvedProfiles = loadedProfiles
        if !resolvedProfiles.contains(where: { $0.id == ServerProfile.hosted.id }) {
            resolvedProfiles.insert(.hosted, at: 0)
            guard runStorageVoid(generation: generation, {
                try profileStore.saveProfiles(resolvedProfiles)
            }) else { return }
        }

        guard let resolvedSelection = resolveSelection(
            among: resolvedProfiles,
            generation: generation
        ) else { return }

        guard isCurrent(generation) else { return }
        profiles = resolvedProfiles
        selectedProfile = resolvedSelection
        reconcileUnselectedPendingCleanupTombstones(selectedProfileID: resolvedSelection.id)
        sessionState = .checkingCompatibility(profile: resolvedSelection)
        await probeAndRestore(profile: resolvedSelection, generation: generation)
    }

    /// At launch, proactively reconciles every durable cleanup tombstone other than
    /// the selected profile's own — whose reconciliation
    /// ``restoreToken(profile:compatibility:generation:)`` already performs as a
    /// precondition of its own token read, immediately below this call.
    ///
    /// Without this, a marker left behind for a profile that is not currently
    /// selected — including one that has since been removed entirely — would never
    /// be retried until (if ever) that exact profile happened to become selected
    /// again, leaving it invisible in ``pendingCleanupFailures`` even though the
    /// underlying tombstone remains fail-safe (every read/save for it stays blocked
    /// regardless; see ``resolvePendingCleanup(for:)``). A selected profile is never
    /// blocked by another, unrelated profile's still-pending cleanup.
    ///
    /// Each reconciliation runs as its own independent, unawaited ``Task`` so it
    /// never delays the selected profile's own compatibility probe/token restore.
    /// This can never race that flow's own concurrent call for the *same* ID (the
    /// selected one is explicitly excluded here), and ``resolvePendingCleanup(for:)``
    /// is itself safe to call concurrently for two *different* profile IDs, or twice
    /// for the same one (it awaits any cleanup already in flight rather than
    /// double-reserving); a later profile switch onto one of these still-reconciling
    /// IDs is likewise safe for the same reason.
    private func reconcileUnselectedPendingCleanupTombstones(selectedProfileID: UUID) {
        guard let pendingIDs = pendingCleanupRegistryIDs() else {
            // Already surfaced session-wide via
            // ``SessionState/credentialCleanupRegistryCorrupted(_:)``, which
            // supersedes the compatibility/token-restore flow this call sits
            // alongside; there is nothing further to reconcile per-profile until
            // that is explicitly, separately resolved.
            return
        }
        for profileID in pendingIDs where profileID != selectedProfileID {
            Task { [weak self] in
                _ = await self?.resolvePendingCleanup(for: profileID)
            }
        }
    }

    /// Restores the persisted selected profile ID, falling back to (and persisting)
    /// hosted when it is absent, does not match a known profile, or its storage is
    /// corrupted.
    ///
    /// A ``ServerProfileStore/loadSelectedProfileID()`` failure is *selection-only*
    /// corruption: ``resolvedProfiles`` (and every profile's token) already decoded
    /// successfully, so there is nothing to discard here. This repairs by silently
    /// falling back to hosted and persisting that repair, exactly as an unknown/absent
    /// selection ID already does — it does *not* route to
    /// ``SessionState/storageCorrupted(_:)``, which conflating this with true
    /// profile-*list* corruption would otherwise do, needlessly offering to erase every
    /// saved profile and token over a corrupt selection pointer alone.
    private func resolveSelection(
        among resolvedProfiles: [ServerProfile],
        generation: Int
    ) -> ServerProfile? {
        let selectedID: UUID?
        do {
            selectedID = try profileStore.loadSelectedProfileID()
        } catch {
            return repairSelectionToHosted(generation: generation)
        }

        if let selectedID, let match = resolvedProfiles.first(where: { $0.id == selectedID }) {
            return match
        }

        return repairSelectionToHosted(generation: generation)
    }

    /// Persists `.hosted` as the repaired selection for
    /// ``resolveSelection(among:generation:)`` — but only if `generation` is still
    /// current: a launch task already superseded (e.g. by a profile switch that raced
    /// this task's disk read/decode failure) must never persist this repair over a
    /// selection a newer, still-current flow already made. Returns `nil` on a stale
    /// generation exactly like every other guard in this file, so the caller's
    /// `guard let ... else { return }` treats it identically.
    private func repairSelectionToHosted(generation: Int) -> ServerProfile? {
        guard isCurrent(generation) else { return nil }
        guard runStorageVoid(generation: generation, {
            try profileStore.saveSelectedProfileID(ServerProfile.hosted.id)
        }) else { return nil }
        return .hosted
    }
}
