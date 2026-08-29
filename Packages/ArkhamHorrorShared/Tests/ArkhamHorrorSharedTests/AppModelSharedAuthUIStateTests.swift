@testable import ArkhamHorrorShared
import Testing

/// Deterministic coverage for the shared-`AppModel` UI-facing state that
/// `ServerSelectionView`/`ServerManagementView` read directly: the entry-point
/// disabled condition (``AppModel/isAuthOperationActive``) and the independence of
/// the two failure channels those views surface (``AppModel/operationFailure`` and
/// ``AppModel/profileManagementFailure``). No SwiftUI or view-inspection tooling is
/// involved: both views read these plain, already-`@Observable` properties directly,
/// so asserting their exact values is equivalent to asserting what the views would
/// render.
extension AppModelTests {
    @Test("isAuthOperationActive is false when idle and true for the duration of a sign-in")
    func isAuthOperationActiveTracksSignIn() async {
        let auth = GatedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        #expect(model.isAuthOperationActive == false)

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        #expect(model.operation == .signingIn)
        #expect(model.isAuthOperationActive == true)

        let activeOperation = model.operationTask
        await auth.resumeOldest(with: .success(.sample))
        await activeOperation?.value

        #expect(model.operation == .idle)
        #expect(model.isAuthOperationActive == false)
    }

    @Test("isAuthOperationActive is true for the duration of a registration")
    func isAuthOperationActiveTracksRegistration() async {
        let auth = GatedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        #expect(model.isAuthOperationActive == false)

        model.beginAuthOperation(.registering) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        #expect(model.isAuthOperationActive == true)

        model.cancelAuthOperation()
        #expect(model.operation == .idle)
        #expect(model.isAuthOperationActive == false)
    }

    @Test(
        """
        A blocked profile-selection interruption and a failed profile-management \
        mutation are independent: setting one never clears, overwrites, or hides the \
        other, so ServerManagementView's footer can (and must) render both at once
        """
    )
    func operationFailureAndProfileManagementFailureAreIndependent() async {
        let cleanupStore = FakeTokenCleanupPendingStore()
        let auth = GatedAuthenticating()
        let profileStore = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile], selectedID: ServerProfile.hosted.id
        )
        let model = AppModel(
            profileStore: profileStore,
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        // First, an add that fails validation sets `profileManagementFailure`.
        model.addCustomProfile(displayName: "Bad", rawURL: "not a url")
        guard case .invalidProfile = model.profileManagementFailure else {
            let failureDescription = String(describing: model.profileManagementFailure)
            Issue.record("Expected .invalidProfile, got \(failureDescription)")
            return
        }
        #expect(model.operationFailure == nil)

        // Now, while that profile-management failure is still present, a blocked
        // profile-selection interruption sets `operationFailure` independently.
        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        let activeOperation = model.operationTask
        cleanupStore.setMarkError(TokenCleanupPendingStoreError.corruptData)
        model.selectProfile(sampleCustomProfile)

        guard case .tokenStore = model.operationFailure else {
            Issue.record(
                "Expected .tokenStore failure, got \(String(describing: model.operationFailure))"
            )
            return
        }
        // The earlier profile-management failure must still be present, untouched by
        // the later, entirely independent operation failure.
        guard case .invalidProfile = model.profileManagementFailure else {
            Issue.record(
                """
                Expected the earlier .invalidProfile failure to survive, got \
                \(String(describing: model.profileManagementFailure))
                """
            )
            return
        }

        // Let the still-active sign-in resolve so nothing is left dangling.
        cleanupStore.setMarkError(nil)
        await auth.resumeOldest(with: .success(.sample))
        await activeOperation?.value
    }
}
