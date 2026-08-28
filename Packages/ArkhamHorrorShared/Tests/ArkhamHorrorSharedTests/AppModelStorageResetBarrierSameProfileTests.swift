@testable import ArkhamHorrorShared
import Testing

/// Regression coverage for same-profile token-operation ordering around the
/// service-wide storage-reset barrier: a running same-profile operation plus a
/// queued same-profile tail must both be drained before `deleteAllTokens()` runs,
/// with no barrier self-deadlock. Split out of `AppModelStorageResetBarrierTests.swift`
/// purely by file size; see that file for the general (cross-profile) barrier coverage
/// and architecture notes.
extension AppModelTests {
    /// Reaches `.storageCorrupted` with `store`/`tokenStore` already wired, exactly as
    /// production startup would after profile-list corruption.
    private func makeCorruptedModel(
        store: FakeServerProfileStore, tokenStore: GatedTokenStore
    ) async -> AppModel {
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        return model
    }

    @Test(
        """
        A running same-profile save plus a queued same-profile save are both drained \
        before delete-all runs, with no barrier deadlock
        """
    )
    func sameProfileRunningPlusQueuedSaveDrainBeforeDeleteAllWithNoDeadlock() async {
        let corruptKey = "ArkhamHorror.serverProfiles"
        let store = FakeServerProfileStore(
            loadProfilesError: ServerProfileStoreError.corruptData(key: corruptKey)
        )
        let tokenStore = GatedTokenStore()
        let model = await makeCorruptedModel(store: store, tokenStore: tokenStore)

        func launchSave(token: String) -> Task<Void, Never> {
            Task {
                await model.performAuthOperation(
                    profile: .hosted, compatibility: .legacy,
                    epochContext: CredentialOperationContext(
                        generation: model.generation,
                        credentialEpoch: model.currentCredentialEpoch(for: ServerProfile.hosted.id),
                        globalEpoch: model.currentGlobalCredentialEpoch()
                    )
                ) { _ in AuthToken(token: token) }
            }
        }

        // Op1: a save for `.hosted`, already suspended inside the token store.
        let op1 = launchSave(token: "op1-token")
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "op1-token", profileID: ServerProfile.hosted.id)]
        )

        // Op2: a SECOND save for the SAME profile, launched before any reset exists.
        // Its own `serializedTokenAccess` call synchronously registers itself as the
        // new tail (capturing the barrier as absent) purely from this enqueue, well
        // before it ever reaches the token store, which happens only once Op1
        // resolves.
        let op2 = launchSave(token: "op2-token")
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "op1-token", profileID: ServerProfile.hosted.id)]
        )

        // The reset is triggered now: `tokenAccessQueues[.hosted.id]` already holds
        // Op2's tail (which transitively awaits Op1). Without capturing the barrier
        // synchronously at Op2's own enqueue time, Op2 would instead dynamically
        // observe this just-installed barrier once its body actually resumes (after
        // Op1 settles) and await it — while the barrier itself is awaiting Op2's own
        // tail, forming a deadlock.
        store.setLoadProfilesError(nil)
        model.confirmStorageReset()

        await tokenStore.resumeOldest()
        await op1.value

        // Op2 must resolve — never hang, and never reach the token store, since its
        // recheck observes the reset's already-bumped global epoch as stale.
        await op2.value
        #expect(await tokenStore.saveCallCount == 1)

        // Only now can the barrier proceed to `deleteAllTokens()`.
        await tokenStore.waitUntilPending(1)
        #expect(await tokenStore.pendingMutations() == [.deleteAll])
        await tokenStore.resumeOldest()
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(await tokenStore.snapshotTokens().isEmpty)
    }

    @Test(
        """
        A running same-profile save plus a queued same-profile cancellation-cleanup \
        tail are both drained before delete-all runs, with no barrier deadlock
        """
    )
    func sameProfileRunningSavePlusQueuedCleanupDrainBeforeDeleteAllWithNoDeadlock() async {
        let corruptKey = "ArkhamHorror.serverProfiles"
        let store = FakeServerProfileStore(
            loadProfilesError: ServerProfileStoreError.corruptData(key: corruptKey)
        )
        let tokenStore = GatedTokenStore()
        let model = await makeCorruptedModel(store: store, tokenStore: tokenStore)

        // Op1: a save for `.hosted`, already suspended inside the token store.
        let op1 = Task {
            await model.performAuthOperation(
                profile: .hosted, compatibility: .legacy, epochContext: CredentialOperationContext(
                    generation: model.generation,
                    credentialEpoch: model.currentCredentialEpoch(for: ServerProfile.hosted.id),
                    globalEpoch: model.currentGlobalCredentialEpoch()
                )
            ) { _ in AuthToken(token: "op1-token") }
        }
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "op1-token", profileID: ServerProfile.hosted.id)]
        )

        // A cancellation-cleanup delete for the SAME profile is enqueued behind Op1,
        // before any reset exists, exactly as `interruptActiveAuthOperationIfNeeded()`
        // would enqueue one behind an in-flight save it is interrupting.
        let cleanupTask = model.enqueueCancellationCleanup(
            for: ServerProfile.hosted.id, globalEpoch: model.currentGlobalCredentialEpoch()
        )
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "op1-token", profileID: ServerProfile.hosted.id)]
        )

        // The reset is triggered now, while the cleanup's tail is already registered.
        // Without a synchronous barrier capture inside `enqueueCancellationCleanup`,
        // this would deadlock exactly as the save case above would.
        store.setLoadProfilesError(nil)
        model.confirmStorageReset()

        await tokenStore.resumeOldest()
        await op1.value

        // The cleanup must resolve — never hang. Its own recheck observes the reset's
        // bumped global epoch as stale, so it never reaches the token store itself
        // (the reset's own `deleteAllTokens()` subsumes it).
        _ = await cleanupTask.value
        #expect(await tokenStore.deleteCallCount == 0)

        await tokenStore.waitUntilPending(1)
        #expect(await tokenStore.pendingMutations() == [.deleteAll])
        await tokenStore.resumeOldest()
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(await tokenStore.snapshotTokens().isEmpty)
    }
}
