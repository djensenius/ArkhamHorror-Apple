@testable import ArkhamHorrorShared
import Testing

private func settle() async {
    for _ in 0 ..< 50 {
        await Task.yield()
    }
}

/// Regression coverage for the durable cancellation-cleanup tombstone: an in-memory-only
/// record of a still-pending cleanup deletion cannot survive an `AppModel`/process
/// reconstruction, so a cancelled operation's save that already durably applied — but
/// whose cleanup delete had not yet (or not successfully) run — could otherwise be
/// silently trusted and restored by a later launch. See
/// `TokenCleanupPendingStore.swift`, `AppModel.swift`
/// (`enqueueCancellationCleanup(for:globalEpoch:)`, `resolvePendingCleanup(for:)`), and
/// `AppModel+Compatibility.swift` (`restoreToken`).
extension AppModelTests {
    @Test(
        """
        A cancellation whose cleanup delete fails leaves a durable tombstone that \
        blocks (and is retried by) a later sign-in for the same profile
        """
    )
    func cancellationCleanupFailureLeavesDurableTombstoneBlockingLaterSignIn() async throws {
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

        // A sign-in's save is already in flight when the user cancels.
        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "cancelled-token") }
        await tokenStore.waitUntilPending(1)
        model.cancelAuthOperation()
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        // The stale save durably applies (it already passed its epoch recheck).
        await tokenStore.resumeOldest()
        await settle()
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "cancelled-token")

        // The cleanup delete cancellation enqueued behind it now reaches the token
        // store — and fails.
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() == [.delete(profileID: ServerProfile.hosted.id)]
        )
        await tokenStore.resumeOldest(throwing: KeychainError.unhandledStatus(-1))
        await settle()

        // The durable tombstone remains pending: the delete failed, so it must not be
        // cleared, and the (still-cancelled) token remains present.
        #expect(cleanupStore.snapshotPendingIDs() == [ServerProfile.hosted.id])
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "cancelled-token")

        // A fresh, legitimate sign-in for the same profile must retry — never bypass —
        // that unresolved cleanup before it is allowed to save its own token.
        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "fresh-token") }
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() == [.delete(profileID: ServerProfile.hosted.id)]
        )

        // This retried delete succeeds: the tombstone clears, and only now can the
        // fresh sign-in's own save proceed.
        await tokenStore.resumeOldest()
        await settle()
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
        Removing a profile whose cleanup delete already failed preserves its durable \
        tombstone, and the removal's own token deletion still succeeds independently
        """
    )
    func removingProfileWithPendingTombstonePreservesIt() async throws {
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
        // The profile's own token is durably gone (removal's own delete succeeded)...
        #expect(try await tokenStore.token(for: sampleCustomProfile.id) == nil)
        // ...but the pre-existing tombstone from the earlier, still-unresolved
        // cancellation cleanup is left exactly as it was: removal must never assume a
        // pending cleanup is resolved just because the profile itself is now gone.
        #expect(cleanupStore.snapshotPendingIDs() == [sampleCustomProfile.id])
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
