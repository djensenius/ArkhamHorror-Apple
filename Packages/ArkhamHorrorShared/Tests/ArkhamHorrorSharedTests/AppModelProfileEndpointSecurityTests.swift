@testable import ArkhamHorrorShared
import Foundation
import Security
import Testing

/// Security-critical custom server profile mutations: endpoint-changing edits and
/// removals, and how each reconciles a profile's Keychain token with its (possibly
/// changed) endpoint. See `AppModelProfileManagementTests.swift` for the companion
/// coverage of add/edit validation, duplicate-endpoint rejection, and
/// display-name/case-only edits that never touch a token.
extension AppModelTests {
    private func makeModel(
        profiles: [ServerProfile] = [.hosted],
        selectedID: UUID? = nil,
        tokenStore: any TokenStore = FakeTokenStore(),
        probe: any CapabilityProbing = ScriptedCapabilityProbe(.outcome(.legacyFallback)),
        auth: any AppAuthenticating = ScriptedAuthenticating()
    ) -> AppModel {
        AppModel(
            profileStore: FakeServerProfileStore(profiles: profiles, selectedID: selectedID),
            tokenStore: tokenStore,
            capabilityProbe: probe,
            authenticationSession: auth
        )
    }

    @Test("An endpoint-changing edit deletes the old token before persisting")
    func endpointChangeDeletesTokenBeforePersisting() async throws {
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "old-token"])
        let model = makeModel(
            profiles: [.hosted, sampleCustomProfile],
            selectedID: sampleCustomProfile.id,
            tokenStore: tokenStore,
            auth: ScriptedAuthenticating(currentUserResult: .success(.sample))
        )
        await model.flowTask?.value

        model.updateCustomProfile(
            sampleCustomProfile,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://new-host.example.com"
        )
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(await tokenStore.deleteCallCount == 1)
        let remaining = try? await tokenStore.token(for: sampleCustomProfile.id)
        #expect(remaining == nil)
        #expect(model.profiles.first { $0.id == sampleCustomProfile.id }?.baseURL.host ==
            "new-host.example.com")
        // The restarted flow probes the new endpoint with no token, reaching signedOut
        // rather than ever presenting the old token to the new origin.
        #expect(try model.sessionState == .signedOut(
            profile: #require(model.profiles.first { $0.id == sampleCustomProfile.id }),
            compatibility: .legacy
        ))
    }

    @Test("A non-selected profile's endpoint-changing edit still deletes its token")
    func endpointChangeForNonSelectedProfileDeletesToken() async {
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "old-token"])
        let model = makeModel(
            profiles: [.hosted, sampleCustomProfile],
            selectedID: nil,
            tokenStore: tokenStore
        )
        await model.flowTask?.value
        #expect(model.selectedProfile.id == ServerProfile.hosted.id)

        model.updateCustomProfile(
            sampleCustomProfile,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://new-host.example.com"
        )
        await model.profileManagementTask?.value

        #expect(await tokenStore.deleteCallCount == 1)
        // The (unrelated) currently selected hosted session is left untouched.
        #expect(model.selectedProfile.id == ServerProfile.hosted.id)
    }

    @Test("A token deletion failure during an endpoint-changing edit preserves the old profile")
    func endpointChangeTokenDeletionFailurePreservesProfile() async {
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "old-token"])
        await tokenStore.setDeleteError(KeychainError.unhandledStatus(errSecAuthFailed))
        let model = makeModel(
            profiles: [.hosted, sampleCustomProfile], tokenStore: tokenStore
        )
        await model.flowTask?.value

        model.updateCustomProfile(
            sampleCustomProfile,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://new-host.example.com"
        )
        await model.profileManagementTask?.value

        let expectedFailure = ProfileManagementFailure.tokenStore(
            .keychain(.unhandledStatus(errSecAuthFailed))
        )
        #expect(model.profileManagementFailure == expectedFailure)
        // The profile list is untouched: the old endpoint (and its still-present
        // token) remain exactly as they were.
        #expect(model.profiles == [.hosted, sampleCustomProfile])
        let remaining = try? await tokenStore.token(for: sampleCustomProfile.id)
        #expect(remaining == "old-token")
    }

    @Test("A persistence failure after token deletion does not silently activate the edit")
    func persistenceFailureAfterTokenDeletionSurfacesFailure() async {
        let store = FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile])
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "old-token"])
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating()
        )
        await model.flowTask?.value

        store.setSaveProfilesError(ServerProfileStoreError.duplicateProfileIDs)
        model.updateCustomProfile(
            sampleCustomProfile,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://new-host.example.com"
        )
        await model.profileManagementTask?.value

        // The token is gone (deleted before the failed persistence attempt) — this
        // never leaves a token pointed at a changed origin — but the edit itself is
        // reported as failed rather than silently treated as applied.
        #expect(await tokenStore.deleteCallCount == 1)
        #expect(model.profileManagementFailure == .storage(.unexpected))
    }

    // MARK: - Remove

    @Test("The hosted profile cannot be removed")
    func removeHostedProfileRejected() async {
        let model = makeModel()
        await model.flowTask?.value

        model.removeCustomProfile(.hosted)

        #expect(model.profileManagementFailure == .cannotModifyHosted)
        #expect(model.profiles == [.hosted])
    }

    @Test("Removing a non-selected custom profile deletes its token then removes it")
    func removeNonSelectedProfileSucceeds() async {
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "token"])
        let model = makeModel(profiles: [.hosted, sampleCustomProfile], tokenStore: tokenStore)
        await model.flowTask?.value
        #expect(model.selectedProfile.id == ServerProfile.hosted.id)

        model.removeCustomProfile(sampleCustomProfile)
        await model.profileManagementTask?.value

        #expect(await tokenStore.deleteCallCount == 1)
        #expect(model.profiles == [.hosted])
        #expect(model.profileManagementFailure == nil)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }

    @Test("Removing the selected profile falls back to hosted and restarts the flow")
    func removeSelectedProfileFallsBackToHosted() async {
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "token"])
        let model = makeModel(
            profiles: [.hosted, sampleCustomProfile],
            selectedID: sampleCustomProfile.id,
            tokenStore: tokenStore
        )
        await model.flowTask?.value
        #expect(model.selectedProfile.id == sampleCustomProfile.id)

        model.removeCustomProfile(sampleCustomProfile)
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(model.profiles == [.hosted])
        #expect(model.selectedProfile == .hosted)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }

    @Test("A token deletion failure during removal preserves the profile")
    func removeTokenDeletionFailurePreservesProfile() async {
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "token"])
        await tokenStore.setDeleteError(KeychainError.unhandledStatus(errSecAuthFailed))
        let model = makeModel(profiles: [.hosted, sampleCustomProfile], tokenStore: tokenStore)
        await model.flowTask?.value

        model.removeCustomProfile(sampleCustomProfile)
        await model.profileManagementTask?.value

        let expectedFailure = ProfileManagementFailure.tokenStore(
            .keychain(.unhandledStatus(errSecAuthFailed))
        )
        #expect(model.profileManagementFailure == expectedFailure)
        #expect(model.profiles == [.hosted, sampleCustomProfile])
    }
}
