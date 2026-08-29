@testable import ArkhamHorrorShared
import Testing

/// Regression coverage for the durable cancellation-cleanup tombstone: an in-memory-only
/// record of a still-pending cleanup deletion cannot survive an `AppModel`/process
/// reconstruction, so a cancelled operation's save that already durably applied — but
/// whose cleanup delete had not yet (or not successfully) run — could otherwise be
/// silently trusted and restored by a later launch. See
/// `TokenCleanupPendingStore.swift`, `AppModel.swift`
/// (`enqueueCancellationCleanup(for:globalEpoch:)`, `resolvePendingCleanup(for:)`), and
/// `AppModel+Compatibility.swift` (`restoreToken`).
extension AppModelTests {
    /// Cancels an in-flight sign-in whose stale save already durably applies (it
    /// already passed its epoch recheck), then lets the cleanup delete cancellation
    /// reserved for it fail, leaving a durable tombstone pending. Shared by the tests
    /// below to keep each within the function-length lint limit.
    private func cancelStaleSaveAndFailCleanupDelete(
        model: AppModel, tokenStore: GatedTokenStore
    ) async {
        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "cancelled-token") }
        await tokenStore.waitUntilPending(1)
        // Captured before `cancelAuthOperation(ownedBy:)` nils it, so the save's completion
        // below can be awaited deterministically instead of inferring it via a fixed
        // number of scheduler yields.
        let staleOperation = model.operationTask
        model.cancelAuthOperation(ownedBy: model.currentAuthAttemptID)
        // Synchronously registered by `enqueueCancellationCleanup` before
        // `cancelAuthOperation(ownedBy:)` returns.
        let cleanupTask = model.cleanupPendingTasks[ServerProfile.hosted.id]?.task

        await tokenStore.resumeOldest()
        await staleOperation?.value

        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest(throwing: KeychainError.unhandledStatus(-1))
        _ = await cleanupTask?.value
    }

    @Test(
        """
        A cancellation whose cleanup delete fails leaves a durable tombstone that \
        blocks a later sign-in for the same profile
        """
    )
    func cancellationCleanupFailureLeavesDurableTombstone() async throws {
        let tokenStore = GatedTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        await cancelStaleSaveAndFailCleanupDelete(model: model, tokenStore: tokenStore)

        // The stale save durably applied (it already passed its epoch recheck), and
        // the cleanup delete failed, so the durable tombstone must remain pending
        // and the (still-cancelled) token remains present.
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "cancelled-token")
        #expect(cleanupStore.snapshotPendingIDs() == [ServerProfile.hosted.id])
    }

    @Test(
        """
        A durable cleanup tombstone is retried — never bypassed — by a later, \
        legitimate sign-in for the same profile, which only saves its own token \
        once that retried cleanup actually resolves it
        """
    )
    func retriedCleanupResolvesTombstoneBeforeFreshSignInSaves() async throws {
        let tokenStore = GatedTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        await cancelStaleSaveAndFailCleanupDelete(model: model, tokenStore: tokenStore)

        // A fresh, legitimate sign-in for the same profile must retry — never bypass —
        // that unresolved cleanup before it is allowed to save its own token.
        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "fresh-token") }
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() == [.delete(profileID: ServerProfile.hosted.id)]
        )
        // Captured now (rather than relying on a fixed number of scheduler yields
        // afterward) so the assertions below cannot flake under CI scheduling
        // pressure: by the time `waitUntilPending` above returned, the retried
        // cleanup's task was already synchronously registered by
        // `enqueueCancellationCleanup` inside `resolvePendingCleanup`.
        let retriedCleanup = model.cleanupPendingTasks[ServerProfile.hosted.id]?.task

        // This retried delete succeeds: the tombstone clears, and only now can the
        // fresh sign-in's own save proceed.
        await tokenStore.resumeOldest()
        _ = await retriedCleanup?.value
        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)

        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "fresh-token", profileID: ServerProfile.hosted.id)]
        )
        await tokenStore.resumeOldest()
        await model.operationTask?.value

        #expect(
            model.sessionState ==
                .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "fresh-token")
    }

    @Test(
        """
        Repeated retries of a durable cleanup tombstone fail, then succeed, before \
        the profile is ever allowed to sign in again
        """
    )
    func repeatedRestoreRetryFailsThenSucceeds() async throws {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "cancelled-token"])
        let cleanupStore = FakeTokenCleanupPendingStore(ids: [ServerProfile.hosted.id])
        await tokenStore.setDeleteError(KeychainError.unhandledStatus(-1))
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))

        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        // Launch itself must retry the pending cleanup before ever reading the token;
        // the retry fails, so the canceled token is neither read nor validated.
        await model.flowTask?.value
        let expectedFailure = SessionUnavailableReason.tokenValidationFailed(
            .tokenStore(.keychain(.unhandledStatus(-1)))
        )
        #expect(model.sessionState == .unavailable(profile: .hosted, reason: expectedFailure))
        #expect(await auth.callOrder.isEmpty)
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "cancelled-token")

        // A first Retry attempt still fails: the tombstone is not cleared by an error
        // being surfaced, nor by pressing Retry.
        model.retry()
        await model.flowTask?.value
        #expect(model.sessionState == .unavailable(profile: .hosted, reason: expectedFailure))
        #expect(cleanupStore.snapshotPendingIDs() == [ServerProfile.hosted.id])

        // The underlying storage recovers; a second Retry now succeeds, clears the
        // tombstone, deletes the canceled token, and reaches `.signedOut` — never
        // `.signedIn` with the canceled token.
        await tokenStore.setDeleteError(nil)
        model.retry()
        await model.flowTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)
    }

    @Test(
        """
        A reconstructed AppModel observes a durable tombstone left by a prior process \
        and never validates or restores the canceled token, even after one failed retry
        """
    )
    func reconstructedAppModelNeverRestoresCanceledTokenAcrossRelaunch() async throws {
        // Shared across two `AppModel` constructions, modeling the same durable
        // Keychain/UserDefaults-backed storage surviving a process relaunch.
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "cancelled-token"])
        let cleanupStore = FakeTokenCleanupPendingStore(ids: [ServerProfile.hosted.id])
        await tokenStore.setDeleteError(KeychainError.unhandledStatus(-1))
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))

        // "Process 1": launch observes the pending tombstone, retries it, fails, and
        // must therefore never contact `whoami` with the canceled token.
        let model1 = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        await model1.flowTask?.value
        guard case .unavailable = model1.sessionState else {
            Issue.record("Expected .unavailable, got \(model1.sessionState)")
            return
        }
        #expect(await auth.callOrder.isEmpty)

        // "Process 2": a fresh relaunch, still with the tombstone unresolved (and the
        // underlying delete still failing) — must reach the exact same conclusion, not
        // silently trust the token merely because this is a new in-memory instance.
        let model2 = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        await model2.flowTask?.value
        guard case .unavailable = model2.sessionState else {
            Issue.record("Expected .unavailable, got \(model2.sessionState)")
            return
        }
        #expect(await auth.callOrder.isEmpty)
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "cancelled-token")

        // The underlying storage now recovers; a third relaunch's retry (via explicit
        // `retry()`) finally succeeds, clears the tombstone, deletes the canceled
        // token, and only then is `whoami` still never contacted for it (the token is
        // gone before it could ever be read for validation).
        await tokenStore.setDeleteError(nil)
        model2.retry()
        await model2.flowTask?.value

        #expect(model2.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)
        #expect(await auth.callOrder.isEmpty)
    }

    @Test("A pending cleanup tombstone blocks a fresh sign-in until it resolves")
    func pendingTombstoneBlocksFreshSignInUntilResolved() async throws {
        let tokenStore = FakeTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore(ids: [ServerProfile.hosted.id])
        await tokenStore.setDeleteError(KeychainError.unhandledStatus(-1))
        let auth = ScriptedAuthenticating(
            authenticateResult: .success(AuthToken(token: "legit-token")),
            currentUserResult: .success(.sample)
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        // No token exists for this profile, so launch's own restore is unaffected by
        // the (unrelated to any stored token) pending tombstone once it resolves as a
        // delete-not-found success — but the delete is currently scripted to fail, so
        // launch itself must surface the same typed failure rather than silently
        // reaching `.signedOut`.
        await model.flowTask?.value
        guard case .unavailable = model.sessionState else {
            Issue.record("Expected .unavailable, got \(model.sessionState)")
            return
        }

        // The underlying storage recovers, and a fresh sign-in is attempted directly
        // via `retry()` re-entering `.signedOut` first, then `signIn(_:)`.
        await tokenStore.setDeleteError(nil)
        model.retry()
        await model.flowTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(cleanupStore.snapshotPendingIDs().isEmpty)

        model.signIn(AuthenticationCredentials(email: "ashcan@example.com", password: "secret"))
        await model.operationTask?.value
        #expect(
            model.sessionState ==
                .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "legit-token")
    }

    @Test(
        """
        Removing a profile with a pre-existing pending tombstone reserves the same \
        durable mark-then-admit cleanup removal always uses, resolving that \
        tombstone as part of its own delete rather than silently leaving it \
        unresolved just because profile metadata is now gone
        """
    )
    func removingProfileWithPendingTombstoneResolvesIt() async throws {
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "some-token"])
        let cleanupStore = FakeTokenCleanupPendingStore(ids: [sampleCustomProfile.id])
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

        model.removeCustomProfile(sampleCustomProfile)
        await model.profileManagementTask?.value

        #expect(model.profiles == [.hosted])
        #expect(model.profileManagementFailure == nil)
        // Removal's own reservation (`enqueueCancellationCleanup`) durably deletes the
        // profile's token before metadata is removed, exactly as an explicit
        // cancellation would...
        #expect(try await tokenStore.token(for: sampleCustomProfile.id) == nil)
        // ...and since that reservation's mark is idempotent against an
        // already-pending tombstone for the very same profile/token, its own
        // successful delete-then-clear resolves the pre-existing tombstone too,
        // rather than silently leaving an unresolved marker behind for a profile
        // that no longer exists.
        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
    }

    @Test("A successful storage reset clears every durable cleanup tombstone")
    func successfulStorageResetClearsAllTombstones() async {
        let corruptKey = "ArkhamHorror.serverProfiles"
        let store = FakeServerProfileStore(
            loadProfilesError: ServerProfileStoreError.corruptData(key: corruptKey)
        )
        let tokenStore = FakeTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore(
            ids: [ServerProfile.hosted.id, sampleCustomProfile.id]
        )
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value
        store.setLoadProfilesError(nil)

        model.confirmStorageReset()
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
    }

    @Test("A failed storage reset preserves every durable cleanup tombstone")
    func failedStorageResetPreservesAllTombstones() async {
        let corruptKey = "ArkhamHorror.serverProfiles"
        let store = FakeServerProfileStore(
            loadProfilesError: ServerProfileStoreError.corruptData(key: corruptKey)
        )
        let tokenStore = FakeTokenStore()
        await tokenStore.setDeleteAllError(KeychainError.unhandledStatus(-1))
        let cleanupStore = FakeTokenCleanupPendingStore(
            ids: [ServerProfile.hosted.id, sampleCustomProfile.id]
        )
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value
        store.setLoadProfilesError(nil)

        model.confirmStorageReset()
        await model.profileManagementTask?.value

        guard case .tokenStore = model.profileManagementFailure else {
            Issue.record(
                "Expected .tokenStore, got \(String(describing: model.profileManagementFailure))"
            )
            return
        }
        #expect(
            cleanupStore.snapshotPendingIDs() == [ServerProfile.hosted.id, sampleCustomProfile.id]
        )
    }
}
