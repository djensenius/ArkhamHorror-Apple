@testable import ArkhamHorrorShared
import Testing

/// Regression coverage for the service-wide storage-reset barrier: `confirmStorageReset()`
/// must not race `deleteAllTokens()` against any per-profile token operation that is
/// already in flight (or arrives while the reset is running), in either direction. See
/// `AppModel+ProfileManagement.swift` (`confirmStorageReset`, `performStorageReset`) and
/// `AppModel.swift` (`serviceResetBarrier`, `globalCredentialEpoch`,
/// `serializedTokenAccess(for:epoch:globalEpoch:_:)`).
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

    @Test("A save already executing when a reset begins is fully awaited before delete-all runs")
    func saveAlreadyExecutingIsAwaitedBeforeDeleteAllRuns() async {
        let corruptKey = "ArkhamHorror.serverProfiles"
        let store = FakeServerProfileStore(
            loadProfilesError: ServerProfileStoreError.corruptData(key: corruptKey)
        )
        let tokenStore = GatedTokenStore()
        let model = await makeCorruptedModel(store: store, tokenStore: tokenStore)
        let expectedFailure = SessionStorageFailure.profileStore(.corruptData(key: corruptKey))
        #expect(model.sessionState == .storageCorrupted(expectedFailure))

        // A save for an arbitrary profile is already mid-flight, suspended inside the
        // token store, when the reset begins.
        let saveTask = Task {
            await model.performAuthOperation(
                profile: .hosted, compatibility: .legacy, epochContext: CredentialOperationContext(
                    generation: model.generation,
                    credentialEpoch: model.currentCredentialEpoch(for: ServerProfile.hosted.id),
                    globalEpoch: model.currentGlobalCredentialEpoch()
                )
            ) { _ in AuthToken(token: "in-flight-token") }
        }
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "in-flight-token", profileID: ServerProfile.hosted.id)]
        )

        store.setLoadProfilesError(nil)
        model.confirmStorageReset()

        // The barrier must await this pre-existing tail before ever calling
        // `deleteAllTokens()` — it must not yet have been reached.
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "in-flight-token", profileID: ServerProfile.hosted.id)]
        )
        #expect(await tokenStore.deleteAllCallCount == 0)

        // Letting the in-flight save durably apply unblocks the barrier, which then
        // (and only then) reaches `deleteAllTokens()`.
        await tokenStore.resumeOldest()
        await saveTask.value
        await tokenStore.waitUntilPending(1)
        #expect(await tokenStore.pendingMutations() == [.deleteAll])
        #expect(await tokenStore.deleteAllCallCount == 1)

        await tokenStore.resumeOldest()
        await model.profileManagementTask?.value
        // The barrier task itself only awaits `performStorageReset`, which spawns the
        // post-reset compatibility/token-restore flow (`restartFlow`) as an
        // independent, unawaited `flowTask` rather than awaiting it inline; the
        // restored token read is nil (everything was just wiped), so this settles to
        // `.signedOut` almost immediately, but it must still be awaited explicitly.
        await model.flowTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(model.profiles == [.hosted])
        #expect(await tokenStore.snapshotTokens().isEmpty)
    }

    @Test(
        """
        Queued stale saves across multiple profiles are all awaited before a reset's delete-all \
        runs
        """
    )
    func queuedStaleSavesAcrossMultipleProfilesAreAllAwaited() async {
        let corruptKey = "ArkhamHorror.serverProfiles"
        let store = FakeServerProfileStore(
            loadProfilesError: ServerProfileStoreError.corruptData(key: corruptKey)
        )
        let tokenStore = GatedTokenStore()
        let model = await makeCorruptedModel(store: store, tokenStore: tokenStore)

        /// Local helper so each save's context construction does not need to be
        /// repeated per profile below.
        func launchSave(profile: ServerProfile, token: String) -> Task<Void, Never> {
            Task {
                await model.performAuthOperation(
                    profile: profile,
                    compatibility: .legacy,
                    epochContext: CredentialOperationContext(
                        generation: model.generation,
                        credentialEpoch: model.currentCredentialEpoch(for: profile.id),
                        globalEpoch: model.currentGlobalCredentialEpoch()
                    )
                ) { _ in AuthToken(token: token) }
            }
        }
        let hostedTask = launchSave(profile: .hosted, token: "hosted-token")
        let customTask = launchSave(profile: sampleCustomProfile, token: "custom-token")
        await tokenStore.waitUntilPending(2)
        #expect(
            await Set(tokenStore.pendingMutations()) == [
                .save(token: "hosted-token", profileID: ServerProfile.hosted.id),
                .save(token: "custom-token", profileID: sampleCustomProfile.id),
            ]
        )

        store.setLoadProfilesError(nil)
        model.confirmStorageReset()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        // Neither pending save may be skipped or overtaken: both are still exactly
        // pending, and delete-all has not yet been reached.
        #expect(await tokenStore.pendingMutations().count == 2)
        #expect(await tokenStore.deleteAllCallCount == 0)

        await tokenStore.resumeOldest()
        await tokenStore.resumeOldest()
        await hostedTask.value
        await customTask.value

        await tokenStore.waitUntilPending(1)
        #expect(await tokenStore.pendingMutations() == [.deleteAll])
        await tokenStore.resumeOldest()
        await model.profileManagementTask?.value

        #expect(model.profiles == [.hosted])
        #expect(await tokenStore.snapshotTokens().isEmpty)
        // The reset must only ever have used the single service-scoped delete-all —
        // never an individual per-profile delete — to clean up either profile's token.
        #expect(await tokenStore.deleteCallCount == 0)
        #expect(await tokenStore.deleteAllCallCount == 1)
    }

    @Test(
        """
        A new save arriving after a reset begins is blocked behind the barrier, never racing \
        delete-all
        """
    )
    func newSaveArrivingDuringResetIsBlockedBehindBarrier() async throws {
        let corruptKey = "ArkhamHorror.serverProfiles"
        let store = FakeServerProfileStore(
            loadProfilesError: ServerProfileStoreError.corruptData(key: corruptKey)
        )
        let tokenStore = GatedTokenStore()
        let model = await makeCorruptedModel(store: store, tokenStore: tokenStore)

        store.setLoadProfilesError(nil)
        model.confirmStorageReset()
        // With no pre-existing tails to await, the barrier reaches `deleteAllTokens()`
        // almost immediately.
        await tokenStore.waitUntilPending(1)
        #expect(await tokenStore.pendingMutations() == [.deleteAll])

        // A brand-new save for an arbitrary profile arrives while the reset's
        // delete-all is still suspended. It must capture the *new* global epoch (as any
        // real caller would, via `currentGlobalCredentialEpoch()`), then block behind
        // the active barrier rather than reaching the token store while delete-all is
        // still pending.
        let newSaveTask = Task {
            await model.performAuthOperation(
                profile: .hosted, compatibility: .legacy, epochContext: CredentialOperationContext(
                    generation: model.generation,
                    credentialEpoch: model.currentCredentialEpoch(for: ServerProfile.hosted.id),
                    globalEpoch: model.currentGlobalCredentialEpoch()
                )
            ) { _ in AuthToken(token: "post-reset-token") }
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(await tokenStore.pendingMutations() == [.deleteAll])

        // Resolve the reset's delete-all: this releases the barrier.
        await tokenStore.resumeOldest()
        await model.profileManagementTask?.value

        // Only now can the new save reach the token store.
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "post-reset-token", profileID: ServerProfile.hosted.id)]
        )
        await tokenStore.resumeOldest()
        await newSaveTask.value

        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "post-reset-token")
    }

    @Test(
        """
        A delete-all failure during reset preserves corrupted metadata and surfaces a typed \
        failure
        """
    )
    func deleteAllFailurePreservesCorruptedMetadata() async {
        let corruptKey = "ArkhamHorror.serverProfiles"
        let store = FakeServerProfileStore(
            loadProfilesError: ServerProfileStoreError.corruptData(key: corruptKey)
        )
        let tokenStore = GatedTokenStore()
        let model = await makeCorruptedModel(store: store, tokenStore: tokenStore)
        let expectedFailure = SessionStorageFailure.profileStore(.corruptData(key: corruptKey))
        #expect(model.sessionState == .storageCorrupted(expectedFailure))

        store.setLoadProfilesError(nil)
        model.confirmStorageReset()
        await tokenStore.waitUntilPending(1)
        #expect(await tokenStore.pendingMutations() == [.deleteAll])

        await tokenStore.resumeOldest(throwing: KeychainError.unhandledStatus(-1))
        await model.profileManagementTask?.value

        // The corrupted state is preserved rather than replaced, and never silently
        // treated as a successful reset.
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

    @Test(
        """
        A successful barrier-coordinated reset persists hosted-only metadata and releases the \
        barrier
        """
    )
    func successfulResetPersistsHostedOnlyMetadataAndReleasesBarrier() async throws {
        let corruptKey = "ArkhamHorror.serverProfiles"
        let store = FakeServerProfileStore(
            loadProfilesError: ServerProfileStoreError.corruptData(key: corruptKey)
        )
        let tokenStore = GatedTokenStore()
        let model = await makeCorruptedModel(store: store, tokenStore: tokenStore)

        store.setLoadProfilesError(nil)
        model.confirmStorageReset()
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest()
        await model.profileManagementTask?.value
        // See the equivalent comment in `saveAlreadyExecutingIsAwaitedBeforeDeleteAllRuns`:
        // the barrier task does not itself await the post-reset `restartFlow`'s
        // independent `flowTask`, so it must be awaited explicitly here too, both to
        // observe the settled `.signedOut` state and to let its (nil, post-wipe) token
        // read fully drain before the follow-up save below starts with a clean queue.
        await model.flowTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(model.profiles == [.hosted])
        #expect(model.selectedProfile == .hosted)
        #expect(store.snapshotProfiles() == [.hosted])
        #expect(store.snapshotSelectedID() == ServerProfile.hosted.id)
        #expect(model.profileManagementFailure == nil)
        #expect(model.profileManagementOperation == .idle)

        // A subsequent save for the (now sole) hosted profile must not be blocked by
        // any leftover barrier state.
        let followUpTask = Task {
            await model.performAuthOperation(
                profile: .hosted, compatibility: .legacy, epochContext: CredentialOperationContext(
                    generation: model.generation,
                    credentialEpoch: model.currentCredentialEpoch(for: ServerProfile.hosted.id),
                    globalEpoch: model.currentGlobalCredentialEpoch()
                )
            ) { _ in AuthToken(token: "post-reset-token") }
        }
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest()
        await followUpTask.value

        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "post-reset-token")
    }

    @Test(
        """
        The barrier is released after a delete-all failure, so a subsequent operation is not \
        permanently blocked
        """
    )
    func barrierIsReleasedAfterFailureAllowingSubsequentOperation() async throws {
        let corruptKey = "ArkhamHorror.serverProfiles"
        let store = FakeServerProfileStore(
            loadProfilesError: ServerProfileStoreError.corruptData(key: corruptKey)
        )
        let tokenStore = GatedTokenStore()
        let model = await makeCorruptedModel(store: store, tokenStore: tokenStore)

        store.setLoadProfilesError(nil)
        model.confirmStorageReset()
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest(throwing: KeychainError.unhandledStatus(-1))
        await model.profileManagementTask?.value

        guard case .tokenStore = model.profileManagementFailure else {
            Issue.record("Expected the reset failure to be recorded before proceeding")
            return
        }

        // A fresh token operation for an arbitrary profile, issued immediately after
        // the failed reset, must not deadlock or be silently skipped: the barrier is
        // released (success or failure) as soon as `deleteAllTokens()` returns.
        let followUpTask = Task {
            await model.performAuthOperation(
                profile: .hosted, compatibility: .legacy, epochContext: CredentialOperationContext(
                    generation: model.generation,
                    credentialEpoch: model.currentCredentialEpoch(for: ServerProfile.hosted.id),
                    globalEpoch: model.currentGlobalCredentialEpoch()
                )
            ) { _ in AuthToken(token: "retry-token") }
        }
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "retry-token", profileID: ServerProfile.hosted.id)]
        )
        await tokenStore.resumeOldest()
        await followUpTask.value

        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "retry-token")
    }
}
