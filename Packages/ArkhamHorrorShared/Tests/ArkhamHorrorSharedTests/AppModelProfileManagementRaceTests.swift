@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Stale-operation guarding for profile management: switching away from a profile
/// while its removal is still in flight, a superseded edit's completion racing a
/// newer edit of the same profile, and explicit storage-corruption recovery. Mirrors
/// the rigor ``AppModelTokenMutationRaceTests`` applies to authentication.
extension AppModelTests {
    private func makeModel(
        profiles: [ServerProfile] = [.hosted],
        selectedID: UUID? = nil,
        tokenStore: any TokenStore = FakeTokenStore()
    ) -> AppModel {
        AppModel(
            profileStore: FakeServerProfileStore(profiles: profiles, selectedID: selectedID),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating()
        )
    }

    /// Builds an edit of `sampleCustomProfile` pointing at a distinct host, so two
    /// overlapping edits of the same profile can be told apart by their resulting URL.
    private func makeEndpointEdit(host: String) throws -> ServerProfile {
        try ServerProfile.custom(
            id: sampleCustomProfile.id,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://\(host).example.com"
        )
    }

    /// Starts `performProfileUpdate` directly at `generation` — the same production
    /// entry point `updateCustomProfile` schedules — to construct two genuinely
    /// overlapping edits of the same profile, which full per-profile token
    /// serialization otherwise makes unreachable through the public
    /// `profileManagementOperation == .idle`-gated API.
    private func launchEndpointEdit(
        on model: AppModel, updated: ServerProfile, generation: Int
    ) -> Task<Void, Never> {
        let credentialEpoch = model.invalidateCredentialEpoch(for: sampleCustomProfile.id)
        return Task {
            await model.performProfileUpdate(
                original: sampleCustomProfile,
                updated: updated,
                endpointChanged: true,
                credentialEpoch: credentialEpoch,
                operationGeneration: generation
            )
        }
    }

    @Test("Switching away from the profile being removed mid-flight does not corrupt state")
    func switchAwayDuringRemovalDoesNotCorruptState() async {
        let tokenStore = GatedTokenStore(tokens: [sampleCustomProfile.id: "token"])
        let model = makeModel(
            profiles: [.hosted, sampleCustomProfile],
            selectedID: sampleCustomProfile.id,
            tokenStore: tokenStore
        )
        await model.flowTask?.value

        model.removeCustomProfile(sampleCustomProfile)
        await tokenStore.waitUntilPending(1)

        // Switch away from the profile being removed while its token deletion is
        // still in flight.
        model.selectProfile(.hosted)
        await model.flowTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        // Resolve the pending deletion. Its completion still removes the (now
        // unselected) profile's metadata, but must not disturb the already-current
        // hosted session state.
        await tokenStore.resumeOldest()
        await model.profileManagementTask?.value

        #expect(model.profiles == [.hosted])
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(model.selectedProfile == .hosted)
    }

    @Test("A superseded profile edit's completion cannot overwrite a newer edit's result")
    func supersededProfileEditCannotOverwriteNewerEdit() async throws {
        let tokenStore = GatedTokenStore(tokens: [sampleCustomProfile.id: "old-token"])
        let model = makeModel(profiles: [.hosted, sampleCustomProfile], tokenStore: tokenStore)
        await model.flowTask?.value

        let firstEdit = try makeEndpointEdit(host: "first-new-host")
        let secondEdit = try makeEndpointEdit(host: "second-new-host")
        func customProfileHost() -> String? {
            model.profiles.first { $0.id == sampleCustomProfile.id }?.baseURL.host
        }

        model.profileManagementGeneration += 1
        let staleTask = launchEndpointEdit(
            on: model, updated: firstEdit, generation: model.profileManagementGeneration
        )
        await tokenStore.waitUntilPending(1)

        model.profileManagementGeneration += 1
        let currentTask = launchEndpointEdit(
            on: model, updated: secondEdit, generation: model.profileManagementGeneration
        )

        // The current edit's delete cannot even be attempted yet: it is serialized
        // behind the stale, still-pending delete for the same profile.
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        #expect(await tokenStore.pendingMutations() == [.delete(profileID: sampleCustomProfile.id)])

        // Resolve the stale delete. Its generation check must discard its completion
        // rather than applying the first host change.
        await tokenStore.resumeOldest()
        await staleTask.value
        #expect(customProfileHost() != firstEdit.baseURL.host)

        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest()
        await currentTask.value

        #expect(customProfileHost() == secondEdit.baseURL.host)
    }

    // MARK: - Storage corruption recovery

    @Test("Storage reset is a no-op outside storageCorrupted")
    func storageResetNoOpWhenNotCorrupted() async {
        let model = makeModel(profiles: [.hosted, sampleCustomProfile])
        await model.flowTask?.value

        model.confirmStorageReset()

        #expect(model.profiles == [.hosted, sampleCustomProfile])
    }

    @Test("Confirming a storage reset reseeds hosted and restarts the flow")
    func confirmStorageResetReseedsHostedAndRestarts() async {
        let corruptKey = "ArkhamHorror.serverProfiles"
        let store = FakeServerProfileStore(
            loadProfilesError: ServerProfileStoreError.corruptData(key: corruptKey)
        )
        let tokenStore = FakeTokenStore()
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating()
        )
        await model.flowTask?.value
        let expectedFailure = SessionStorageFailure.profileStore(.corruptData(key: corruptKey))
        #expect(model.sessionState == .storageCorrupted(expectedFailure))

        store.setLoadProfilesError(nil)
        model.confirmStorageReset()
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(model.profiles == [.hosted])
        #expect(model.selectedProfile == .hosted)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(store.snapshotProfiles() == [.hosted])
        #expect(store.snapshotSelectedID() == ServerProfile.hosted.id)
        // A full profile-list-corruption reset must securely clean up every stored
        // token before ever replacing the corrupted metadata.
        #expect(await tokenStore.deleteAllCallCount == 1)
    }

    @Test("A cleanup failure during storage reset preserves corrupted metadata, typed failure")
    func storageResetCleanupFailurePreservesCorruptedMetadata() async {
        let corruptKey = "ArkhamHorror.serverProfiles"
        let store = FakeServerProfileStore(
            loadProfilesError: ServerProfileStoreError.corruptData(key: corruptKey)
        )
        let tokenStore = FakeTokenStore()
        await tokenStore.setDeleteAllError(KeychainError.unhandledStatus(-1))
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating()
        )
        await model.flowTask?.value
        let expectedFailure = SessionStorageFailure.profileStore(.corruptData(key: corruptKey))
        #expect(model.sessionState == .storageCorrupted(expectedFailure))

        // The stored profiles remain corrupt/unreadable, but a genuinely fresh
        // read attempt would still fail — this reset must never even get that far,
        // since token cleanup itself fails first.
        model.confirmStorageReset()
        await model.profileManagementTask?.value

        // The corrupted state must be preserved rather than replaced.
        #expect(model.sessionState == .storageCorrupted(expectedFailure))
        #expect(store.saveProfilesCallCount == 0)
        #expect(store.saveSelectionCallCount == 0)
        guard case .tokenStore = model.profileManagementFailure else {
            Issue.record(
                "Expected .tokenStore, got \(String(describing: model.profileManagementFailure))"
            )
            return
        }
        #expect(model.profileManagementOperation == .idle)
    }
}
