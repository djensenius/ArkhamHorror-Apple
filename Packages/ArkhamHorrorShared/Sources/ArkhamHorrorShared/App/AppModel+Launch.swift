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
    /// hosted when it is absent or does not match a known profile.
    private func resolveSelection(
        among resolvedProfiles: [ServerProfile],
        generation: Int
    ) -> ServerProfile? {
        guard let selectedID = runStorage(generation: generation, {
            try profileStore.loadSelectedProfileID()
        }) else { return nil }

        if let selectedID, let match = resolvedProfiles.first(where: { $0.id == selectedID }) {
            return match
        }

        guard runStorageVoid(generation: generation, {
            try profileStore.saveSelectedProfileID(ServerProfile.hosted.id)
        }) else { return nil }
        return .hosted
    }
}
