@testable import ArkhamHorrorShared
import Testing

/// Fail-closed durable cleanup-reservation ordering coverage for registration and for
/// endpoint-changing profile edit/removal — split out of
/// `AppModelCleanupTombstoneFailClosedTests.swift` to stay within the file-length lint
/// limit.
///
/// Every caller that must interrupt or protect an in-flight credential mutation
/// (``AppModel/cancelAuthOperation(ownedBy:)``,
/// ``AppModel/interruptActiveAuthOperationIfNeeded()``,
/// ``AppModel/updateCustomProfile(_:displayName:rawURL:)``,
/// ``AppModel/removeCustomProfile(_:)``) reserves the same durable mark-then-admit
/// cleanup (``AppModel/enqueueCancellationCleanup(for:globalEpoch:)``) *before*
/// mutating any generation/credential epoch/operation state/selection/profile
/// metadata. A `markPending` failure must therefore leave every one of those
/// untouched and surface a typed, retryable failure instead — never silently
/// proceeding, and never orphaning a genuinely active operation past its own ability
/// to ever complete.
extension AppModelTests {
    @Test(
        """
        A markPending failure during explicit cancellation of an in-flight \
        registration fails closed exactly as it does for sign-in: the operation is \
        not reported as cancelled, generation/epoch are left untouched, and it \
        completes normally once its whoami resolves
        """
    )
    func explicitCancellationOfRegistrationMarkPendingFailureFailsClosed() async throws {
        let tokenStore = FakeTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let auth = GatedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        model.beginAuthOperation(.registering) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        #expect(model.operation == .registering)
        let activeOperation = model.operationTask
        let generationBeforeCancel = model.generation

        cleanupStore.setMarkError(TokenCleanupPendingStoreError.corruptData)
        #expect(model.cancelAuthOperation(ownedBy: model.currentAuthAttemptID) == false)

        #expect(model.operation == .registering)
        #expect(model.generation == generationBeforeCancel)
        guard case .tokenStore = model.authFailure?.failure else {
            Issue.record(
                "Expected .tokenStore failure, got \(String(describing: model.authFailure))"
            )
            return
        }

        await auth.resumeOldest(with: .success(.sample))
        await activeOperation?.value
        #expect(
            model.sessionState ==
                .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "issued-token")
    }

    @Test(
        """
        A markPending failure while editing a custom profile's endpoint fails \
        closed: neither the profile list nor its token are mutated, the failure is \
        typed and actionable, and retrying once the store recovers succeeds normally
        """
    )
    func updateCustomProfileMarkPendingFailureFailsClosed() async throws {
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "existing-token"])
        let cleanupStore = FakeTokenCleanupPendingStore()
        let profileStore = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile], selectedID: ServerProfile.hosted.id
        )
        let model = AppModel(
            profileStore: profileStore,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value
        let profilesBeforeEdit = model.profiles

        cleanupStore.setMarkError(TokenCleanupPendingStoreError.corruptData)
        model.updateCustomProfile(
            sampleCustomProfile,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://different-host.example.com"
        )
        await model.profileManagementTask?.value

        // The reservation itself could not be made durable: the profile list, the
        // still-editable profile's token, and `profileManagementOperation` are all
        // left exactly as they were, rather than half-applying the edit or leaving
        // the old token exposed to a persisted-but-unprotected endpoint change.
        #expect(model.profiles == profilesBeforeEdit)
        #expect(try await tokenStore.token(for: sampleCustomProfile.id) == "existing-token")
        #expect(model.profileManagementOperation == .idle)
        guard case .tokenStore = model.profileManagementFailure else {
            Issue.record(
                """
                Expected .tokenStore failure, got \
                \(String(describing: model.profileManagementFailure))
                """
            )
            return
        }

        // Retrying once the store recovers succeeds normally: the edit is applied
        // and the old token is durably deleted first.
        cleanupStore.setMarkError(nil)
        model.updateCustomProfile(
            sampleCustomProfile,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://different-host.example.com"
        )
        await model.profileManagementTask?.value

        #expect(model.profileManagementFailure == nil)
        #expect(model.profiles.contains { $0.baseURL.host == "different-host.example.com" })
        #expect(try await tokenStore.token(for: sampleCustomProfile.id) == nil)
    }

    @Test(
        """
        A markPending failure while removing a custom profile fails closed: the \
        profile and its token are left untouched, the failure is typed and \
        actionable, and retrying once the store recovers removes it normally
        """
    )
    func removeCustomProfileMarkPendingFailureFailsClosed() async throws {
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "existing-token"])
        let cleanupStore = FakeTokenCleanupPendingStore()
        let profileStore = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile], selectedID: ServerProfile.hosted.id
        )
        let model = AppModel(
            profileStore: profileStore,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value
        let profilesBeforeRemoval = model.profiles

        cleanupStore.setMarkError(TokenCleanupPendingStoreError.corruptData)
        model.removeCustomProfile(sampleCustomProfile)
        await model.profileManagementTask?.value

        #expect(model.profiles == profilesBeforeRemoval)
        #expect(try await tokenStore.token(for: sampleCustomProfile.id) == "existing-token")
        #expect(model.profileManagementOperation == .idle)
        guard case .tokenStore = model.profileManagementFailure else {
            Issue.record(
                """
                Expected .tokenStore failure, got \
                \(String(describing: model.profileManagementFailure))
                """
            )
            return
        }

        // Retrying once the store recovers removes the profile normally: the token
        // is durably deleted first, then the metadata.
        cleanupStore.setMarkError(nil)
        model.removeCustomProfile(sampleCustomProfile)
        await model.profileManagementTask?.value

        #expect(model.profileManagementFailure == nil)
        #expect(model.profiles == [.hosted])
        #expect(try await tokenStore.token(for: sampleCustomProfile.id) == nil)
    }
}
