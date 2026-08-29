@testable import ArkhamHorrorShared
import Security
import Testing

/// Storage-reset interaction with observable pending-cleanup failures — split out of
/// `AppModelPendingCleanupFailureTests.swift` purely to stay within the file-length
/// lint limit. See that file's own documentation for the full rationale behind
/// `pendingCleanupFailures`/`retryPendingCleanup(for:)` in general; these tests cover
/// specifically that a successful ``AppModel/confirmStorageReset()`` clears every
/// observable failure (the underlying tombstones and tokens are gone too, so there is
/// nothing left to retry) while a *failed* reset preserves them exactly as they were
/// (so nothing is falsely reported as resolved).
extension AppModelTests {
    private struct CleanupTestFailure: Error {}

    @Test("A successful storage reset clears every observable pending-cleanup failure")
    func successfulStorageResetClearsPendingCleanupFailures() async throws {
        let tokenStore = GatedTokenStore()
        let auth = GatedAuthenticating()
        // `saveSelectionError` is scripted from construction (rather than via a
        // later setter) purely so the very first `saveSelectedProfileID` call this
        // test makes — the one that drives this model into `.storageCorrupted` — is
        // the one that fails; it is cleared again below before the reset itself
        // needs that same call to succeed.
        let store = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile],
            selectedID: ServerProfile.hosted.id,
            saveSelectionError: ServerProfileStoreError.duplicateProfileIDs
        )
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        // Seed a real, observable pending-cleanup failure on this exact model while
        // it is still signed out.
        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        model.cancelAuthOperation(ownedBy: model.currentAuthAttemptID)
        let cleanupTask = model.cleanupPendingTasks[ServerProfile.hosted.id]?.task
        try #require(cleanupTask != nil)
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest(throwing: CleanupTestFailure())
        _ = await cleanupTask?.value
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id] != nil)

        // Now switch profiles, which fails at the scripted `saveSelectedProfileID`
        // and drives this same model into `.storageCorrupted` — the pending-cleanup
        // failure seeded above is unrelated to this failure and remains recorded.
        model.selectProfile(sampleCustomProfile)
        guard case .storageCorrupted = model.sessionState else {
            Issue.record("Expected .storageCorrupted, got \(model.sessionState)")
            return
        }
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id] != nil)

        store.setSaveSelectionError(nil)
        model.confirmStorageReset()
        await tokenStore.waitUntilPending(1)
        #expect(await tokenStore.pendingMutations() == [.deleteAll])
        await tokenStore.resumeOldest()
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(model.pendingCleanupFailures.isEmpty)
    }

    @Test("A failed storage reset preserves every observable pending-cleanup failure")
    func failedStorageResetPreservesPendingCleanupFailures() async throws {
        let tokenStore = FakeTokenStore()
        let auth = GatedAuthenticating()
        let store = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile],
            selectedID: ServerProfile.hosted.id,
            saveSelectionError: ServerProfileStoreError.duplicateProfileIDs
        )
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        // Seed a real, observable pending-cleanup failure via an explicit delete
        // failure, exactly like `explicitCancelDeleteFailureIsObservableAndRetryable`.
        await tokenStore.setDeleteError(KeychainError.unhandledStatus(errSecIO))
        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        model.cancelAuthOperation(ownedBy: model.currentAuthAttemptID)
        let cleanupTask = model.cleanupPendingTasks[ServerProfile.hosted.id]?.task
        try #require(cleanupTask != nil)
        _ = await cleanupTask?.value
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id] != nil)
        await tokenStore.setDeleteError(nil)

        // Switching profiles fails at the scripted `saveSelectedProfileID`, driving
        // this model into `.storageCorrupted` — unrelated to the pending-cleanup
        // failure seeded above, which remains recorded throughout.
        model.selectProfile(sampleCustomProfile)
        guard case .storageCorrupted = model.sessionState else {
            Issue.record("Expected .storageCorrupted, got \(model.sessionState)")
            return
        }
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id] != nil)

        // The reset's own required first step — deleting every stored token — now
        // fails, so the reset must stop before ever reaching (or clearing) any
        // pending-cleanup failure.
        await tokenStore.setDeleteAllError(KeychainError.unhandledStatus(errSecIO))
        model.confirmStorageReset()
        await model.profileManagementTask?.value

        guard case .tokenStore = model.profileManagementFailure else {
            Issue.record(
                "Expected .tokenStore, got \(String(describing: model.profileManagementFailure))"
            )
            return
        }
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id] != nil)
    }
}
