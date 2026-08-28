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
        sessionState = .checkingCompatibility(profile: resolvedSelection)
        await probeAndRestore(profile: resolvedSelection, generation: generation)
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
            guard runStorageVoid(generation: generation, {
                try profileStore.saveSelectedProfileID(ServerProfile.hosted.id)
            }) else { return nil }
            return .hosted
        }

        if let selectedID, let match = resolvedProfiles.first(where: { $0.id == selectedID }) {
            return match
        }

        guard runStorageVoid(generation: generation, {
            try profileStore.saveSelectedProfileID(ServerProfile.hosted.id)
        }) else { return nil }
        return .hosted
    }
}
