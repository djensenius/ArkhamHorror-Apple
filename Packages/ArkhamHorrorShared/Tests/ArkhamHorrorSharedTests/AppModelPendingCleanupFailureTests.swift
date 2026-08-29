@testable import ArkhamHorrorShared
import Security
import Testing

/// Deterministic coverage for cancellation/profile-switch cleanup **failures**
/// actually being observable and actionable, rather than fire-and-forget: a reserved
/// durable tombstone (see `AppModel+CredentialEpoch.swift`,
/// `enqueueCancellationCleanup(for:globalEpoch:)`) already blocks any read, restore,
/// or save for the affected profile regardless of whether its own delete or marker
/// clear ever succeeds — but without `pendingCleanupFailures`/`retryPendingCleanup(for:)`
/// there was previously no way for the current UI/route to know a cleanup needed a
/// retry at all, nor any way to force one. These tests drive real delete/clear
/// failures via `GatedTokenStore`/`FakeTokenCleanupPendingStore` and assert the
/// resulting failure is recorded, retryable, and correctly scoped so a stale
/// completion can never overwrite or clear a newer operation's own outcome.
extension AppModelTests {
    private struct CleanupTestFailure: Error {}

    /// A model already signed out into `sampleCustomProfile`, wired to gated `auth`
    /// and `tokenStore` fakes. Factored out purely to keep
    /// ``staleCleanupCompletionCannotOverwriteNewerOutcome()`` within the function-body
    /// length lint limit.
    private func makeSignedOutCustomProfileModel(
        tokenStore: GatedTokenStore, auth: GatedAuthenticating
    ) async -> AppModel {
        let profileStore = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile], selectedID: sampleCustomProfile.id
        )
        let model = AppModel(
            profileStore: profileStore,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        return model
    }

    @Test(
        """
        A token-delete failure after an explicit sign-in cancellation is recorded as \
        an observable, retryable pending-cleanup failure, and a subsequent retry \
        resolves it
        """
    )
    func explicitCancelDeleteFailureIsObservableAndRetryable() async throws {
        let tokenStore = GatedTokenStore()
        let auth = GatedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "cancelled-token") }
        await auth.waitUntilPending(1)
        #expect(model.operation == .signingIn)

        // Cancellation reserves the durable tombstone and enqueues its delete
        // synchronously, before returning here.
        model.cancelAuthOperation(ownedBy: model.currentAuthAttemptID)
        #expect(model.operation == .idle)
        #expect(model.operationFailure == nil)
        let cleanupTask = model.cleanupPendingTasks[ServerProfile.hosted.id]?.task
        try #require(cleanupTask != nil)

        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.delete(profileID: ServerProfile.hosted.id)]
        )
        await tokenStore.resumeOldest(throwing: CleanupTestFailure())
        let outcome = await cleanupTask?.value

        #expect(outcome == .other)
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id]?.failure == .other)
        // Cancellation itself must remain silent: the auth operation was never
        // reported as failed by this — only the cleanup obligation is now visible.
        #expect(model.operationFailure == nil)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        // The pruned tracking entry means a retry must reserve and enqueue an
        // entirely fresh delete attempt.
        #expect(model.cleanupPendingTasks[ServerProfile.hosted.id] == nil)
        let retryTask = Task { await model.retryPendingCleanup(for: ServerProfile.hosted.id) }
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.delete(profileID: ServerProfile.hosted.id)]
        )
        await tokenStore.resumeOldest()
        let retryOutcome = await retryTask.value

        #expect(retryOutcome == nil)
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id] == nil)
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)
    }

    @Test(
        """
        Repeated retries of a cleanup that keeps failing stay actionable (the \
        failure is never silently dropped) until one finally succeeds
        """
    )
    func retryStaysActionableAcrossRepeatedFailures() async throws {
        let tokenStore = GatedTokenStore()
        let auth = GatedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "cancelled-token") }
        await auth.waitUntilPending(1)
        model.cancelAuthOperation(ownedBy: model.currentAuthAttemptID)
        let firstCleanupTask = model.cleanupPendingTasks[ServerProfile.hosted.id]?.task
        try #require(firstCleanupTask != nil)

        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest(throwing: CleanupTestFailure())
        // Awaited explicitly (rather than inferred via scheduling) so the tracking
        // entry this attempt owns is guaranteed pruned before the next retry is
        // started — otherwise `retryPendingCleanup` would simply re-observe this
        // exact same (already-resolved) task instead of enqueueing a genuinely new
        // delete attempt, and the test's next `waitUntilPending` would then hang
        // forever waiting for a mutation that was never issued.
        #expect(await firstCleanupTask?.value == .other)
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id]?.failure == .other)
        #expect(model.cleanupPendingTasks[ServerProfile.hosted.id] == nil)

        // First retry also fails.
        let firstRetry = Task { await model.retryPendingCleanup(for: ServerProfile.hosted.id) }
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest(throwing: CleanupTestFailure())
        #expect(await firstRetry.value == .other)
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id]?.failure == .other)
        #expect(model.cleanupPendingTasks[ServerProfile.hosted.id] == nil)

        // Second retry finally succeeds and fully resolves the obligation.
        let secondRetry = Task { await model.retryPendingCleanup(for: ServerProfile.hosted.id) }
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest()
        #expect(await secondRetry.value == nil)
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id] == nil)
    }

    @Test(
        """
        A cleanup-marker clear failure after the token delete itself already \
        succeeded still leaves the obligation pending and retryable
        """
    )
    func markerClearFailureAfterSuccessfulDeleteStaysPendingAndRetryable() async throws {
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

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "cancelled-token") }
        await auth.waitUntilPending(1)

        cleanupStore.setClearError(TokenCleanupPendingStoreError.corruptData)
        let cleanupTask = { () -> Task<TokenStoreFailure?, Never>? in
            model.cancelAuthOperation(ownedBy: model.currentAuthAttemptID)
            return model.cleanupPendingTasks[ServerProfile.hosted.id]?.task
        }()
        try #require(cleanupTask != nil)
        let outcome = await cleanupTask?.value

        // The delete itself succeeded (nothing to find, since this token was never
        // saved), but its required tombstone clear failed — the token store's delete
        // count still reflects a genuine attempt.
        #expect(await tokenStore.deleteCallCount == 1)
        #expect(outcome == .other)
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id]?.failure == .other)
        #expect(cleanupStore.snapshotPendingIDs().contains(ServerProfile.hosted.id))

        // Retrying with the clear error still in place fails identically and stays
        // pending.
        let repeatOutcome = await model.retryPendingCleanup(for: ServerProfile.hosted.id)
        #expect(repeatOutcome == .other)
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id]?.failure == .other)

        // Once the marker store recovers, retrying resolves everything.
        cleanupStore.setClearError(nil)
        let finalOutcome = await model.retryPendingCleanup(for: ServerProfile.hosted.id)
        #expect(finalOutcome == nil)
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id] == nil)
        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
    }

    @Test(
        """
        Switching away from a profile with an in-flight sign-in reserves that \
        profile's cleanup and completes the switch immediately; a later delete \
        failure for the old profile is observable/retryable without disturbing the \
        already-switched selection
        """
    )
    func profileSwitchInterruptDeleteFailureAfterSelectionChanges() async throws {
        let tokenStore = GatedTokenStore()
        let auth = GatedAuthenticating()
        let profileStore = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile], selectedID: ServerProfile.hosted.id
        )
        let model = AppModel(
            profileStore: profileStore,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        #expect(model.selectedProfile == .hosted)

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "abandoned-token") }
        await auth.waitUntilPending(1)
        #expect(model.operation == .signingIn)

        model.selectProfile(sampleCustomProfile)

        // The switch itself proceeds immediately once the old profile's cleanup is
        // durably reserved — it does not wait for the delete to actually finish.
        #expect(model.selectedProfile == sampleCustomProfile)
        #expect(model.operationFailure == nil)
        let cleanupTask = model.cleanupPendingTasks[ServerProfile.hosted.id]?.task
        try #require(cleanupTask != nil)
        await model.flowTask?.value
        #expect(
            model.sessionState == .signedOut(profile: sampleCustomProfile, compatibility: .legacy)
        )

        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.delete(profileID: ServerProfile.hosted.id)]
        )
        await tokenStore.resumeOldest(throwing: CleanupTestFailure())
        let outcome = await cleanupTask?.value

        #expect(outcome == .other)
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id]?.failure == .other)
        // The already-completed switch is entirely unaffected by the old profile's
        // cleanup outcome.
        #expect(model.selectedProfile == sampleCustomProfile)
        #expect(
            model.sessionState == .signedOut(profile: sampleCustomProfile, compatibility: .legacy)
        )

        let retryTask = Task { await model.retryPendingCleanup(for: ServerProfile.hosted.id) }
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest()
        #expect(await retryTask.value == nil)
        #expect(model.pendingCleanupFailures[ServerProfile.hosted.id] == nil)
    }

    @Test(
        """
        A stale, superseded cleanup attempt's own late failure/success can never \
        overwrite or clear a newer cleanup attempt's own recorded outcome for the \
        same profile
        """
    )
    func staleCleanupCompletionCannotOverwriteNewerOutcome() async throws {
        let tokenStore = GatedTokenStore()
        let auth = GatedAuthenticating()
        let model = await makeSignedOutCustomProfileModel(tokenStore: tokenStore, auth: auth)
        #expect(model.selectedProfile == sampleCustomProfile)

        // First cleanup (cancel #1) for `sampleCustomProfile` is reserved and its
        // delete is enqueued.
        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        model.cancelAuthOperation(ownedBy: model.currentAuthAttemptID)
        let firstCleanupTask = model.cleanupPendingTasks[sampleCustomProfile.id]?.task
        try #require(firstCleanupTask != nil)
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() == [.delete(profileID: sampleCustomProfile.id)]
        )

        // Before cancel #1's delete resolves, an endpoint-changing edit for the same
        // profile reserves its *own* cleanup, chained strictly behind the first —
        // this genuinely overlaps two in-flight cleanups for one profile, exactly as
        // an endpoint edit racing an explicit cancellation would in production.
        let editTask = Task {
            model.updateCustomProfile(
                sampleCustomProfile,
                displayName: sampleCustomProfile.displayName,
                rawURL: "https://second-endpoint.example.com"
            )
        }
        // Give `updateCustomProfile`'s synchronous reservation a chance to register
        // before this test proceeds: it runs entirely synchronously up to and
        // including installing the second cleanup's tracking entry, so awaiting the
        // (synchronous) call itself is sufficient — no arbitrary yield is needed.
        let secondSubmission = await editTask.value
        try #require(secondSubmission != nil)
        let secondCleanupTask = model.cleanupPendingTasks[sampleCustomProfile.id]?.task
        try #require(secondCleanupTask != nil)

        // Cancel #1's delete now fails. Because the edit's own reservation already
        // superseded cancel #1's tracking entry, this failure must never be recorded
        // as the profile's observable outcome.
        await tokenStore.resumeOldest(throwing: CleanupTestFailure())
        _ = await firstCleanupTask?.value
        #expect(model.pendingCleanupFailures[sampleCustomProfile.id] == nil)

        // Cancel #2 (the edit's own reservation)'s delete now runs and is the one
        // that actually determines the profile's observable outcome.
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() == [.delete(profileID: sampleCustomProfile.id)]
        )
        await tokenStore.resumeOldest(throwing: KeychainError.unhandledStatus(errSecIO))
        let secondOutcome = await secondCleanupTask?.value

        guard case .keychain = secondOutcome else {
            Issue.record("Expected .keychain, got \(String(describing: secondOutcome))")
            return
        }
        guard case .keychain = model.pendingCleanupFailures[sampleCustomProfile.id]?.failure else {
            let failure = model.pendingCleanupFailures[sampleCustomProfile.id]
            let description = String(describing: failure)
            Issue.record("Expected a .keychain pending failure, got \(description)")
            return
        }

        // The endpoint edit itself must not have proceeded/persisted, since its own
        // cleanup ultimately failed.
        await model.profileManagementTask?.value
        #expect(model.profiles.first { $0.id == sampleCustomProfile.id }?.baseURL ==
            sampleCustomProfile.baseURL)
    }
}
