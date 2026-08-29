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
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
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
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
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
        // reported as failed (using the actual store error, not a generic fallback)
        // rather than silently treated as applied.
        #expect(await tokenStore.deleteCallCount == 1)
        #expect(model.profileManagementFailure == .storage(.profileStore(.duplicateProfileIDs)))
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

    @Test("A persistence failure during removal stays local and never forces storageCorrupted")
    func removePersistenceFailureStaysLocal() async {
        let store = FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile])
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "token"])
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        let stateBeforeRemove = model.sessionState

        store.setSaveProfilesError(ServerProfileStoreError.duplicateProfileIDs)
        model.removeCustomProfile(sampleCustomProfile)
        await model.profileManagementTask?.value

        // The token is already durably deleted (removal cannot leave an orphaned
        // token for a profile it fails to remove from the list), but the failed
        // persistence itself must stay local to `profileManagementFailure` rather
        // than forcing the whole session into the storage-corrupted recovery flow.
        #expect(await tokenStore.deleteCallCount == 1)
        #expect(model.sessionState == stateBeforeRemove)
        #expect(model.profileManagementFailure == .storage(.profileStore(.duplicateProfileIDs)))
        #expect(model.profiles == [.hosted, sampleCustomProfile])
    }

    @Test("An endpoint-changing edit of the selected profile resets a stuck auth operation")
    func endpointChangeOfSelectedProfileResetsInFlightAuthOperation() async throws {
        // A slow whoami validation (the same fake and pattern used by
        // `AppModelAuthOperationTests`'s cancellation coverage) stands in for any
        // in-flight sign-in/register at the moment the endpoint-changing edit lands.
        // No token is preloaded for the selected profile: `GatedAuthenticating`'s
        // `currentUser` never resolves on its own, so a preloaded token would make the
        // model's own launch-time token restoration hang on the very first `whoami`
        // call, before this test ever reaches its own `beginAuthOperation`.
        let auth = GatedAuthenticating()
        let tokenStore = FakeTokenStore()
        let model = makeModel(
            profiles: [.hosted, sampleCustomProfile],
            selectedID: sampleCustomProfile.id,
            tokenStore: tokenStore,
            auth: auth
        )
        await model.flowTask?.value
        #expect(
            model.sessionState == .signedOut(profile: sampleCustomProfile, compatibility: .legacy)
        )

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        #expect(model.operation == .signingIn)

        // Captured before the endpoint-changing edit (which resets `operationTask`
        // to `nil` exactly as `cancelAuthOperation(ownedBy:)` does), so this test can
        // deterministically await the stale operation's own completion below instead
        // of inferring scheduler progress with a fixed number of yields.
        // `operationTask`'s body runs end to end with no further unawaited
        // indirection, so awaiting it fully waits for any save attempt this stale
        // operation could still make.
        let staleOperation = model.operationTask

        model.updateCustomProfile(
            sampleCustomProfile,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://new-host.example.com"
        )
        await model.profileManagementTask?.value
        await model.flowTask?.value

        // The restarted flow for the edited endpoint must not be left stuck behind a
        // stale in-flight operation: `operation` and its task handle are reset exactly
        // as `selectProfile(_:)`/`retry()`/`cancelAuthOperation(ownedBy:)` already do, so the
        // new sign-in/register UI is not permanently disabled.
        #expect(model.operation == .idle)
        #expect(model.operationFailure == nil)
        #expect(model.operationTask == nil)
        let editedProfile = try #require(model.profiles.first { $0.id == sampleCustomProfile.id })
        #expect(model.sessionState == .signedOut(profile: editedProfile, compatibility: .legacy))

        // The abandoned whoami now resolves successfully, out of order, well after the
        // edit; it must not resurrect a session or save a token for either endpoint.
        await auth.resumeOldest(with: .success(.sample))
        await staleOperation?.value

        #expect(model.sessionState == .signedOut(profile: editedProfile, compatibility: .legacy))
        #expect(await tokenStore.saveCallCount == 0)
    }
}
