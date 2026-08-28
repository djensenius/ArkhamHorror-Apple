@testable import ArkhamHorrorShared
import Foundation
import Security
import Testing

/// Deterministic coverage for custom server profile management: add/edit/remove
/// validation, hosted protections, duplicate detection, token deletion ordering on
/// endpoint-changing edits and removal, persistence-failure handling, stale-operation
/// guarding across profile switches, and explicit storage-corruption recovery.
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

    // MARK: - Add

    @Test("Adding a valid custom profile persists it and clears any prior failure")
    func addCustomProfileSucceeds() async {
        let model = makeModel()
        await model.flowTask?.value

        model.addCustomProfile(displayName: "Home Lab", rawURL: "https://lab.example.com")

        #expect(model.profiles.count == 2)
        #expect(model.profiles.last?.displayName == "Home Lab")
        #expect(model.profiles.last?.kind == .custom)
        #expect(model.profileManagementFailure == nil)
        #expect(model.profileManagementOperation == .idle)
    }

    @Test("Adding a profile with an invalid URL surfaces the exact validation failure")
    func addCustomProfileInvalidURL() async {
        let model = makeModel()
        await model.flowTask?.value

        model.addCustomProfile(displayName: "Bad", rawURL: "ftp://example.com")

        #expect(model.profiles.count == 1)
        #expect(model.profileManagementFailure == .invalidProfile(.unsupportedScheme))
    }

    @Test("Adding a profile with a duplicate endpoint is rejected")
    func addCustomProfileDuplicateEndpoint() async {
        let model = makeModel(profiles: [.hosted, sampleCustomProfile])
        await model.flowTask?.value

        model.addCustomProfile(
            displayName: "Different name", rawURL: sampleCustomProfile.baseURL.absoluteString
        )

        #expect(model.profiles.count == 2)
        #expect(model.profileManagementFailure == .duplicateEndpoint)
    }

    // MARK: - Edit: hosted protection, validation, duplicate

    @Test("The hosted profile cannot be edited")
    func editHostedProfileRejected() async {
        let model = makeModel()
        await model.flowTask?.value

        model.updateCustomProfile(.hosted, displayName: "Renamed", rawURL: "https://example.com")

        #expect(model.profileManagementFailure == .cannotModifyHosted)
        #expect(model.profiles == [.hosted])
    }

    @Test("Editing an unknown profile is rejected")
    func editUnknownProfileRejected() async throws {
        let model = makeModel(profiles: [.hosted, sampleCustomProfile])
        await model.flowTask?.value
        let unknown = try ServerProfile.custom(
            displayName: "Ghost", rawURL: "https://ghost.example.com"
        )

        model.updateCustomProfile(
            unknown, displayName: "Ghost", rawURL: "https://ghost.example.com"
        )

        #expect(model.profileManagementFailure == .profileNotFound)
    }

    @Test("Editing a profile to an invalid URL surfaces the exact validation failure")
    func editCustomProfileInvalidURL() async {
        let model = makeModel(profiles: [.hosted, sampleCustomProfile])
        await model.flowTask?.value

        model.updateCustomProfile(
            sampleCustomProfile, displayName: "Self-hosted", rawURL: "user:pass@example.com"
        )
        await model.profileManagementTask?.value

        #expect(model.profileManagementFailure == .invalidProfile(.credentialsNotAllowed))
        #expect(model.profiles == [.hosted, sampleCustomProfile])
    }

    @Test("Editing a profile to another saved profile's endpoint is rejected")
    func editCustomProfileDuplicateEndpoint() async throws {
        let other = try ServerProfile.custom(
            displayName: "Other", rawURL: "https://other.example.com"
        )
        let model = makeModel(profiles: [.hosted, sampleCustomProfile, other])
        await model.flowTask?.value

        model.updateCustomProfile(
            other, displayName: other.displayName,
            rawURL: sampleCustomProfile.baseURL.absoluteString
        )

        #expect(model.profileManagementFailure == .duplicateEndpoint)
        #expect(model.profiles == [.hosted, sampleCustomProfile, other])
    }

    // MARK: - Edit: display-name-only retains the token

    @Test("A display-name-only edit persists the rename and never touches the token")
    func renameOnlyEditRetainsToken() async {
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "kept-token"])
        let model = makeModel(
            profiles: [.hosted, sampleCustomProfile],
            selectedID: sampleCustomProfile.id,
            tokenStore: tokenStore,
            auth: ScriptedAuthenticating(currentUserResult: .success(.sample))
        )
        await model.flowTask?.value
        let signedIn = SessionState.signedIn(
            profile: sampleCustomProfile, compatibility: .legacy, user: .sample
        )
        #expect(model.sessionState == signedIn)

        model.updateCustomProfile(
            sampleCustomProfile,
            displayName: "Renamed Self-Host",
            rawURL: sampleCustomProfile.baseURL.absoluteString
        )
        await model.profileManagementTask?.value

        #expect(model.profileManagementFailure == nil)
        #expect(model.profiles.first { $0.id == sampleCustomProfile.id }?.displayName ==
            "Renamed Self-Host")
        #expect(await tokenStore.deleteCallCount == 0)
        #expect(model.selectedProfile.displayName == "Renamed Self-Host")
        if case let .signedIn(profile, _, _) = model.sessionState {
            #expect(profile.displayName == "Renamed Self-Host")
        } else {
            Issue.record("Expected signedIn state with the renamed profile")
        }
    }

    // MARK: - Edit: endpoint change deletes the token first

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
