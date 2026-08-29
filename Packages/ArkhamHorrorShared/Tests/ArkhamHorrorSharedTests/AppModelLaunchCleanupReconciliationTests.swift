@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Regression coverage for launch-time reconciliation of every durable
/// cleanup-tombstone marker — not only the selected profile's own, which
/// `restoreToken(profile:compatibility:generation:)` already reconciles as a
/// precondition of its own token read. See `AppModel+Launch.swift`
/// (`reconcileUnselectedPendingCleanupTombstones(selectedProfileID:)`).
extension AppModelTests {
    /// An unselected profile's durable cleanup tombstone left behind by a prior
    /// process is fully resolved (token deleted, marker cleared) at relaunch,
    /// without delaying or otherwise affecting the selected profile's own flow.
    @Test(
        """
        Relaunch reconciles an unselected profile's durable cleanup tombstone \
        without blocking the selected profile's own flow
        """
    )
    func relaunchReconcilesUnselectedTombstoneWithoutBlockingSelected() async throws {
        let profileStore = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile], selectedID: sampleCustomProfile.id
        )
        let tokenStore = GatedTokenStore(tokens: [ServerProfile.hosted.id: "abandoned-token"])
        let cleanupStore = FakeTokenCleanupPendingStore(ids: [ServerProfile.hosted.id])
        let model = AppModel(
            profileStore: profileStore,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )

        // The reconciliation task for the unselected (hosted) profile's tombstone is
        // independent of, and never awaited by, `flowTask` itself, so this waits on
        // the gated store's own signal that the delete it drives has actually been
        // invoked — never a fixed number of scheduler yields.
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.delete(profileID: ServerProfile.hosted.id)]
        )
        // Synchronously registered by `enqueueCancellationCleanup` before this
        // reconciliation task's own call could have suspended on the gate above.
        let reconciliationTask = model.cleanupPendingTasks[ServerProfile.hosted.id]?.task

        await tokenStore.resumeOldest()
        _ = await reconciliationTask?.value
        await model.flowTask?.value

        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id] == nil)

        // The selected profile's own flow was never blocked by the unrelated,
        // unselected profile's tombstone.
        #expect(model.selectedProfile == sampleCustomProfile)
        #expect(
            model.sessionState ==
                .signedOut(profile: sampleCustomProfile, compatibility: .legacy)
        )
    }

    /// An unselected profile's cleanup failure remains visibly, actionably pending
    /// (rather than silently forgotten) after relaunch, and a subsequent explicit
    /// retry for that exact profile resolves it — without ever affecting the
    /// selected profile.
    @Test(
        """
        An unselected profile's cleanup failure remains visible/retryable after \
        relaunch, and retrying it resolves it without affecting the selected profile
        """
    )
    func relaunchSurfacesUnselectedCleanupFailureAndRetryResolvesIt() async throws {
        let profileStore = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile], selectedID: sampleCustomProfile.id
        )
        let tokenStore = GatedTokenStore(tokens: [ServerProfile.hosted.id: "abandoned-token"])
        let cleanupStore = FakeTokenCleanupPendingStore(ids: [ServerProfile.hosted.id])
        let model = AppModel(
            profileStore: profileStore,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )

        await tokenStore.waitUntilPending(1)
        let reconciliationTask = model.cleanupPendingTasks[ServerProfile.hosted.id]?.task
        await tokenStore.resumeOldest(throwing: KeychainError.unhandledStatus(-1))
        _ = await reconciliationTask?.value
        await model.flowTask?.value

        // The tombstone remains durably pending, and the failure is visible and
        // actionable rather than silently pruned merely because the profile it
        // belongs to is not the one currently selected.
        #expect(cleanupStore.snapshotPendingIDs() == [ServerProfile.hosted.id])
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id] != nil)
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "abandoned-token")
        #expect(model.selectedProfile == sampleCustomProfile)
        #expect(
            model.sessionState ==
                .signedOut(profile: sampleCustomProfile, compatibility: .legacy)
        )

        // Retrying the exact (still-unselected) profile resolves it.
        let retryTask = Task {
            await model.retryPendingCleanup(for: ServerProfile.hosted.id)
        }
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest()
        _ = await retryTask.value

        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id] == nil)
        #expect(model.selectedProfile == sampleCustomProfile)
    }

    /// A durable marker left behind for a profile ID that no longer corresponds to
    /// any saved profile (e.g. it was since removed) is still safely reconciled at
    /// relaunch rather than crashing or being silently ignored.
    @Test("A durable tombstone for an unknown/removed profile ID is reconciled safely at relaunch")
    func relaunchReconcilesUnknownProfileIDTombstoneSafely() async {
        let unknownProfileID = UUID()
        let profileStore = FakeServerProfileStore(
            profiles: [.hosted], selectedID: ServerProfile.hosted.id
        )
        let tokenStore = GatedTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore(ids: [unknownProfileID])
        let model = AppModel(
            profileStore: profileStore,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )

        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() == [.delete(profileID: unknownProfileID)]
        )
        let reconciliationTask = model.cleanupPendingTasks[unknownProfileID]?.task
        await tokenStore.resumeOldest()
        _ = await reconciliationTask?.value
        await model.flowTask?.value

        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
        #expect(model.pendingCleanupFailures[unknownProfileID] == nil)
        #expect(model.selectedProfile == .hosted)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }
}
