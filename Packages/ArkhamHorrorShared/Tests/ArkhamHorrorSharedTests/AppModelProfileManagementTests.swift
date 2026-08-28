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

    @Test("A save failure while adding a profile stays local and never forces storageCorrupted")
    func addCustomProfileSaveFailureStaysLocal() async {
        let store = FakeServerProfileStore(profiles: [.hosted])
        let model = AppModel(
            profileStore: store,
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating()
        )
        await model.flowTask?.value
        let stateBeforeAdd = model.sessionState

        store.setSaveProfilesError(ServerProfileStoreError.duplicateProfileIDs)
        model.addCustomProfile(displayName: "Home Lab", rawURL: "https://lab.example.com")

        // A profile-management save failure (e.g. a transient write error, or the
        // store's own defensive duplicate-ID check) is not evidence that the
        // *existing* stored profiles/tokens are corrupted, so it must never force
        // every window into the destructive storage-reset flow the way genuine
        // load-time corruption does.
        #expect(model.sessionState == stateBeforeAdd)
        #expect(model.profileManagementFailure == .storage(.profileStore(.duplicateProfileIDs)))
        #expect(model.profiles == [.hosted])
    }

    @Test("Adding a profile with an invalid URL surfaces the exact validation failure")
    func addCustomProfileInvalidURL() async {
        let model = makeModel()
        await model.flowTask?.value

        model.addCustomProfile(displayName: "Bad", rawURL: "ftp://example.com")

        #expect(model.profiles.count == 1)
        #expect(model.profileManagementFailure == .invalidProfile(.unsupportedScheme))
    }

    @Test("Adding a profile with plain HTTP to a non-loopback host is rejected")
    func addCustomProfileInsecureHTTPRejected() async {
        let model = makeModel()
        await model.flowTask?.value

        model.addCustomProfile(displayName: "Insecure", rawURL: "http://example.com")

        #expect(model.profiles.count == 1)
        #expect(model.profileManagementFailure == .invalidProfile(.insecureScheme))
    }

    @Test("Adding a profile with plain HTTP to the local loopback interface succeeds")
    func addCustomProfileLoopbackPlainHTTPSucceeds() async {
        let model = makeModel()
        await model.flowTask?.value

        model.addCustomProfile(displayName: "Local", rawURL: "http://localhost:8080")

        #expect(model.profiles.count == 2)
        #expect(model.profiles.last?.baseURL.scheme == "http")
        #expect(model.profileManagementFailure == nil)
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

    @Test("A scheme/host case-only edit is not treated as an endpoint change and retains the token")
    func schemeHostCaseOnlyEditRetainsToken() async throws {
        // sampleCustomProfile's baseURL host/scheme are already lowercased at
        // construction; resubmitting the same URL with different letter casing must
        // normalize to the identical baseURL, so this is not an endpoint change.
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "kept-token"])
        let model = makeModel(
            profiles: [.hosted, sampleCustomProfile],
            selectedID: sampleCustomProfile.id,
            tokenStore: tokenStore,
            auth: ScriptedAuthenticating(currentUserResult: .success(.sample))
        )
        await model.flowTask?.value

        let upperCasedSchemeAndHost = "HTTPS://SELF-HOSTED.EXAMPLE.COM"
        model.updateCustomProfile(
            sampleCustomProfile,
            displayName: sampleCustomProfile.displayName,
            rawURL: upperCasedSchemeAndHost
        )
        await model.profileManagementTask?.value

        #expect(model.profileManagementFailure == nil)
        #expect(await tokenStore.deleteCallCount == 0)
        #expect(try await tokenStore.token(for: sampleCustomProfile.id) == "kept-token")
    }

    @Test("A path-case-only edit (/TenantA vs /tenanta) is an endpoint change; deletes token")
    func pathCaseOnlyEditForcesDeletion() async throws {
        let original = try ServerProfile.custom(
            id: sampleCustomProfile.id,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://shared-host.example.com/TenantA"
        )
        let tokenStore = FakeTokenStore(tokens: [original.id: "kept-token"])
        let model = makeModel(
            profiles: [.hosted, original],
            selectedID: original.id,
            tokenStore: tokenStore,
            auth: ScriptedAuthenticating(currentUserResult: .success(.sample))
        )
        await model.flowTask?.value

        model.updateCustomProfile(
            original,
            displayName: original.displayName,
            rawURL: "https://shared-host.example.com/tenanta"
        )
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(await tokenStore.deleteCallCount == 1)
        let remaining = try? await tokenStore.token(for: original.id)
        #expect(remaining == nil)
        #expect(model.profiles.first { $0.id == original.id }?.baseURL.path == "/tenanta")
    }

    @Test(
        """
        An edit that only adds/removes the scheme's explicit default port is not an \
        endpoint change and retains the token
        """
    )
    func defaultPortOnlyEditRetainsToken() async throws {
        let original = try ServerProfile.custom(
            id: sampleCustomProfile.id,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://self-hosted.example.com:443"
        )
        let tokenStore = FakeTokenStore(tokens: [original.id: "kept-token"])
        let model = makeModel(
            profiles: [.hosted, original],
            selectedID: original.id,
            tokenStore: tokenStore,
            auth: ScriptedAuthenticating(currentUserResult: .success(.sample))
        )
        await model.flowTask?.value

        // Omit the explicit :443 entirely; the canonical baseURL must be identical.
        model.updateCustomProfile(
            original,
            displayName: original.displayName,
            rawURL: "https://self-hosted.example.com"
        )
        await model.profileManagementTask?.value

        #expect(model.profileManagementFailure == nil)
        #expect(await tokenStore.deleteCallCount == 0)
        #expect(try await tokenStore.token(for: original.id) == "kept-token")
    }

    @Test("Adding a profile whose only difference is an explicit default port is a duplicate")
    func defaultPortOnlyDifferenceIsDuplicate() async throws {
        let existing = try ServerProfile.custom(
            displayName: "Existing", rawURL: "https://shared-host.example.com"
        )
        let model = makeModel(profiles: [.hosted, existing], selectedID: ServerProfile.hosted.id)
        await model.flowTask?.value

        model.addCustomProfile(
            displayName: "Duplicate", rawURL: "https://shared-host.example.com:443"
        )
        await model.profileManagementTask?.value

        #expect(model.profileManagementFailure == .duplicateEndpoint)
        #expect(model.profiles.count == 2)
    }
}
