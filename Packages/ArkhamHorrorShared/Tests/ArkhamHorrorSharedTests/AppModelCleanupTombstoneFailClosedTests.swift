@testable import ArkhamHorrorShared
import Testing

/// Fail-closed durable cancellation-cleanup tombstone coverage: split out of
/// `AppModelCleanupTombstoneTests.swift` to stay within the file-length lint limit.
///
/// A durable `markPending`/`clearPending`/`clearAll` failure must never be treated as
/// though cleanup succeeded — production must fail closed (block the operation,
/// preserve prior state, and surface a typed, retryable failure) rather than silently
/// proceeding as if the tombstone were resolved. See
/// `AppModel+CredentialEpoch.swift` (`enqueueCancellationCleanup(for:globalEpoch:)`,
/// `resolvePendingCleanup(for:)`) and `AppModel+ProfileManagement.swift`
/// (`performStorageReset`).
extension AppModelTests {
    @Test(
        """
        A markPending failure during explicit cancellation fails closed: the \
        operation is not reported as cancelled, its generation/epoch are left \
        untouched so it is not orphaned, and it completes normally once its whoami \
        resolves
        """
    )
    func explicitCancellationMarkPendingFailureFailsClosed() async throws {
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
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        #expect(model.operation == .signingIn)
        // Captured before cancellation so the still-active operation's own eventual
        // completion can be awaited deterministically below rather than inferring
        // scheduler progress.
        let activeOperation = model.operationTask
        let generationBeforeCancel = model.generation

        cleanupStore.setMarkError(TokenCleanupPendingStoreError.corruptData)
        model.cancelAuthOperation(ownedBy: model.currentAuthAttemptID)

        // Cancellation must not be reported as having succeeded while its cleanup
        // could not be durably reserved: `operation`, `generation`, and
        // `operationTask` are all left exactly as they were — the reservation is
        // attempted *before* any mutation, so a mark failure cannot orphan the
        // genuinely active operation (bumping it past its own ability to ever
        // complete while never actually cleaning it up) — and the failure is
        // surfaced as an actionable, typed error rather than a silent cancellation.
        #expect(model.operation == .signingIn)
        #expect(model.generation == generationBeforeCancel)
        #expect(model.operationTask != nil)
        guard case .tokenStore = model.authFailure?.failure else {
            Issue.record(
                "Expected .tokenStore failure, got \(String(describing: model.authFailure))"
            )
            return
        }
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        // No deletion could have been enqueued (mark itself failed), so there is
        // nothing pending to observe here — this is not a tombstone-durability gap,
        // since no cleanup was ever reserved in the first place.
        #expect(cleanupStore.snapshotPendingIDs().isEmpty)

        // The genuinely active whoami now resolves successfully. Since cancellation's
        // reservation failed and left generation/epoch untouched, this operation was
        // never orphaned — it completes exactly as an uninterrupted sign-in would,
        // actually saving its token and transitioning to signed-in.
        await auth.resumeOldest(with: .success(.sample))
        await activeOperation?.value
        #expect(
            model.sessionState ==
                .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "issued-token")

        // A further cancellation attempt (e.g. a late Cancel-button tap racing the
        // completed sign-in) is now a safe no-op, since `operation` is no longer
        // `.signingIn`/`.registering`.
        cleanupStore.setMarkError(nil)
        model.cancelAuthOperation(ownedBy: model.currentAuthAttemptID)
        #expect(model.operation == .idle)
        #expect(model.authFailure == nil)
        #expect(
            model.sessionState ==
                .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )
    }

    @Test(
        """
        A markPending failure while switching profiles away from an in-flight \
        sign-in fails closed: the switch does not proceed, generation/epoch are left \
        untouched so the sign-in is not orphaned, and it completes normally once its \
        whoami resolves
        """
    )
    func profileSwitchMarkPendingFailureFailsClosed() async throws {
        let tokenStore = FakeTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let auth = GatedAuthenticating()
        let profileStore = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile], selectedID: ServerProfile.hosted.id
        )
        let model = AppModel(
            profileStore: profileStore,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value
        #expect(model.selectedProfile == .hosted)

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        #expect(model.operation == .signingIn)
        let activeOperation = model.operationTask
        let generationBeforeSwitch = model.generation

        cleanupStore.setMarkError(TokenCleanupPendingStoreError.corruptData)
        model.selectProfile(sampleCustomProfile)

        // The switch's own selection/persistence must not proceed while its
        // interruption's cleanup could not be durably reserved: the selected profile,
        // `generation`, and the in-flight operation are all left exactly as they
        // were — the reservation is attempted *before* any mutation, so a mark
        // failure cannot orphan the genuinely active sign-in — and the failure is
        // surfaced as typed and actionable.
        #expect(model.selectedProfile == .hosted)
        #expect(model.generation == generationBeforeSwitch)
        #expect(model.operation == .signingIn)
        guard case .tokenStore = model.operationFailure else {
            Issue.record(
                "Expected .tokenStore failure, got \(String(describing: model.operationFailure))"
            )
            return
        }
        #expect(profileStore.saveSelectionCallCount == 0)

        // The genuinely active whoami now resolves successfully. Since the switch's
        // reservation failed and left generation/epoch untouched, this operation was
        // never orphaned — it completes exactly as an uninterrupted sign-in would,
        // actually saving its token and transitioning to signed-in for the profile
        // the switch attempted (and failed) to move away from.
        await auth.resumeOldest(with: .success(.sample))
        await activeOperation?.value
        #expect(
            model.sessionState ==
                .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "issued-token")
        #expect(model.selectedProfile == .hosted)

        // The switch can now be retried normally: there is no in-flight operation
        // left to interrupt, so this proceeds as an ordinary profile switch.
        cleanupStore.setMarkError(nil)
        model.selectProfile(sampleCustomProfile)
        await model.flowTask?.value
        #expect(model.selectedProfile == sampleCustomProfile)
        #expect(model.operation == .idle)
        #expect(model.operationFailure == nil)
    }

    /// Cancels an in-flight sign-in whose cleanup delete succeeds but whose
    /// tombstone-clear fails (having pre-armed `cleanupStore` for that failure),
    /// resuming the operation's gated `whoami` and awaiting the cleanup task to
    /// resolve. Shared by the tests below to keep each within the
    /// function-length lint limit; asserts (rather than returns) the failure so a
    /// caller cannot silently proceed against an unexpectedly-succeeded cleanup.
    private func cancelSignInWithFailingClear(
        model: AppModel, auth: GatedAuthenticating, cleanupStore: FakeTokenCleanupPendingStore
    ) async {
        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "cancelled-token") }
        await auth.waitUntilPending(1)

        // The delete this cancellation reserves will succeed, but clearing the
        // tombstone afterward will not.
        cleanupStore.setClearError(TokenCleanupPendingStoreError.corruptData)
        model.cancelAuthOperation(ownedBy: model.currentAuthAttemptID)
        // Synchronously registered by `enqueueCancellationCleanup` before
        // `cancelAuthOperation(ownedBy:)` returns, so this is available deterministically
        // rather than by inferring scheduler progress.
        let cleanupTask = model.cleanupPendingTasks[ServerProfile.hosted.id]?.task

        await auth.resumeOldest(with: .success(.sample))
        let cleanupOutcome = await cleanupTask?.value
        guard cleanupOutcome != nil else {
            Issue.record(
                """
                Expected a failure from the failed clear, got \
                \(String(describing: cleanupOutcome))
                """
            )
            return
        }
    }

    @Test(
        """
        A clearPending failure after the cancelled token is actually deleted leaves \
        the tombstone pending and blocks a subsequent auth attempt for the same \
        profile
        """
    )
    func clearPendingFailureAfterDeletionBlocksSubsequentAuth() async throws {
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

        await cancelSignInWithFailingClear(model: model, auth: auth, cleanupStore: cleanupStore)

        // The delete actually ran (the token this cancellation was cleaning up is
        // gone), even though clearing the tombstone that records it failed afterward
        // — so the durable tombstone must still be present.
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)
        #expect(cleanupStore.snapshotPendingIDs() == [ServerProfile.hosted.id])

        // A fresh sign-in attempt must retry — never bypass — the still-pending
        // cleanup; since clearing still fails, it must stay blocked rather than
        // silently saving a new token behind an unresolved tombstone.
        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "should-not-save") }
        await model.operationTask?.value
        guard case .tokenStore = model.authFailure?.failure else {
            Issue.record(
                """
                Expected sign-in to remain blocked by the still-pending tombstone, got \
                \(String(describing: model.authFailure))
                """
            )
            return
        }
        #expect(model.operation == .idle)
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)
        #expect(cleanupStore.snapshotPendingIDs() == [ServerProfile.hosted.id])
        #expect(await tokenStore.saveCallCount == 0)
    }

    @Test(
        """
        Once a clearPending failure is resolved by a recovered store, a retried \
        sign-in for the same profile actually saves its own fresh token
        """
    )
    func clearPendingRetrySucceedsAndSavesFreshTokenAfterRecovery() async throws {
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

        await cancelSignInWithFailingClear(model: model, auth: auth, cleanupStore: cleanupStore)

        // The store recovers; retrying now resolves the tombstone and allows a fresh
        // sign-in to actually save its own token.
        cleanupStore.setClearError(nil)
        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "fresh-token") }
        // This attempt's own `whoami` reaches the same gated actor and must be
        // resumed explicitly — unlike the first attempt, nothing else resumes it.
        await auth.waitUntilPending(1)
        await auth.resumeOldest(with: .success(.sample))
        await model.operationTask?.value

        #expect(
            model.sessionState ==
                .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "fresh-token")
        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
    }

    @Test(
        """
        A clearAll failure after a storage reset's deleteAllTokens already succeeded \
        preserves the old (corrupted) metadata and every tombstone, surfaces a typed \
        failure, and is retryable
        """
    )
    func clearAllFailureAfterDeleteAllSucceedsPreservesMetadataAndTombstones() async {
        let corruptKey = "ArkhamHorror.serverProfiles"
        let store = FakeServerProfileStore(
            loadProfilesError: ServerProfileStoreError.corruptData(key: corruptKey)
        )
        let tokenStore = FakeTokenStore(
            tokens: [ServerProfile.hosted.id: "old-token", sampleCustomProfile.id: "other-token"]
        )
        let cleanupStore = FakeTokenCleanupPendingStore(
            ids: [ServerProfile.hosted.id, sampleCustomProfile.id]
        )
        cleanupStore.setClearError(TokenCleanupPendingStoreError.corruptData)
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value
        guard case .storageCorrupted = model.sessionState else {
            Issue.record("Expected .storageCorrupted, got \(model.sessionState)")
            return
        }
        store.setLoadProfilesError(nil)

        model.confirmStorageReset()
        await model.profileManagementTask?.value

        // `deleteAllTokens()` itself succeeded (every token is durably gone)...
        #expect(await tokenStore.snapshotTokens().isEmpty)
        // ...but `clearAll()` failed, so metadata replacement must not have happened,
        // every tombstone must remain, and the failure must be surfaced as typed and
        // actionable rather than silently reporting reset success.
        guard case .tokenStore = model.profileManagementFailure else {
            Issue.record(
                "Expected .tokenStore, got \(String(describing: model.profileManagementFailure))"
            )
            return
        }
        #expect(
            cleanupStore.snapshotPendingIDs() == [ServerProfile.hosted.id, sampleCustomProfile.id]
        )
        guard case .storageCorrupted = model.sessionState else {
            Issue.record("Expected .storageCorrupted to be preserved, got \(model.sessionState)")
            return
        }

        // The store recovers; retrying now succeeds end to end (its own
        // `deleteAllTokens()` is idempotent, finding nothing left to delete).
        cleanupStore.setClearError(nil)
        model.confirmStorageReset()
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
    }
}
