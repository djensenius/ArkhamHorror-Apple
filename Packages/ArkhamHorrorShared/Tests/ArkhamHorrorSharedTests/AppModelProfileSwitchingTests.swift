@testable import ArkhamHorrorShared
import Testing

private func settle() async {
    for _ in 0 ..< 50 {
        await Task.yield()
    }
}

/// Profile switching, stale completions, retry, and credential retention checks.
extension AppModelTests {
    @Test("Switching profiles persists the selection and restarts the flow")
    func switchingProfilesPersistsAndRestarts() async {
        let store = FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile])
        let model = AppModel(
            profileStore: store,
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        model.selectProfile(sampleCustomProfile)
        await model.flowTask?.value

        #expect(store.snapshotSelectedID() == sampleCustomProfile.id)
        let expectedSignedOut = SessionState.signedOut(
            profile: sampleCustomProfile, compatibility: .legacy
        )
        #expect(model.sessionState == expectedSignedOut)
    }

    @Test("A stale compatibility completion from before a profile switch cannot mutate state")
    func staleCompletionAfterProfileSwitchIsIgnored() async {
        let store = FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile])
        let gate = GatedCapabilityProbe()
        let model = AppModel(
            profileStore: store,
            tokenStore: FakeTokenStore(),
            capabilityProbe: gate,
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )

        // The launch flow's probe(hosted) call is now suspended, mid-flight.
        await gate.waitUntilPending(1)
        let staleFlowTask = model.flowTask

        // Switching profiles cancels the outer task (ignored by this fake, which never
        // checks cancellation) and starts a second, independent probe call.
        model.selectProfile(sampleCustomProfile)
        await gate.waitUntilPending(2)

        // Resolve the new (current-generation, most recently issued) call first so the
        // model settles. The stale hosted-profile call was issued first and remains
        // pending.
        await gate.resumeNewest(with: .legacyFallback)
        await model.flowTask?.value
        let expectedSignedOut = SessionState.signedOut(
            profile: sampleCustomProfile, compatibility: .legacy
        )
        #expect(model.sessionState == expectedSignedOut)

        // Now resolve the stale hosted-profile call with a conflicting outcome. Its
        // completion must be discarded rather than overwrite the current state.
        await gate.resumeOldest(with: .compatible(capabilities: ["should-not-apply"]))
        _ = await staleFlowTask?.value

        #expect(model.sessionState == expectedSignedOut)
    }

    @Test("Retry re-probes the currently unavailable profile")
    func retryReprobesUnavailableProfile() async {
        let probe = ScriptedCapabilityProbe(.failure(CapabilityProbeError.nonHTTPResponse))
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: probe,
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        let expected = SessionState.unavailable(
            profile: .hosted, reason: .probeFailed(.nonHTTPResponse)
        )
        #expect(model.sessionState == expected)

        model.retry()
        await model.flowTask?.value

        #expect(await probe.callCount == 2)
        #expect(model.sessionState == expected)
    }

    @Test("The coordinator never retains submitted credentials as a stored property")
    func credentialsAreNotRetained() async {
        let secret = "extremely-secret-password"
        let auth = ScriptedAuthenticating(authenticateResult: .failure(TestFailure()))
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        model.signIn(AuthenticationCredentials(email: "a@example.com", password: secret))
        await model.operationTask?.value

        func containsSecret(_ value: Any) -> Bool {
            if let string = value as? String, string.contains(secret) {
                return true
            }
            let mirror = Mirror(reflecting: value)
            return mirror.children.contains { containsSecret($0.value) }
        }

        #expect(!containsSecret(model))
    }

    @Test(
        """
        Switching profiles while a sign-in save is in flight (already past its epoch \
        check) interrupts it exactly as explicit cancellation would, deleting the \
        token it durably applies
        """
    )
    func switchingAwayDuringInFlightSaveInterruptsAndDeletesToken() async throws {
        let store = FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile])
        let tokenStore = GatedTokenStore()
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "abandoned-token") }
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "abandoned-token", profileID: ServerProfile.hosted.id)]
        )

        // The user switches to a different server before the in-flight save resolves.
        model.selectProfile(sampleCustomProfile)
        await model.flowTask?.value
        let expectedSignedOut = SessionState.signedOut(
            profile: sampleCustomProfile, compatibility: .legacy
        )
        #expect(model.sessionState == expectedSignedOut)
        #expect(model.selectedProfile == sampleCustomProfile)

        // The abandoned save durably applies — it already passed its epoch recheck
        // before the switch invalidated it for anything *afterward*.
        await tokenStore.resumeOldest()
        await settle()
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "abandoned-token")

        // The switch's own interruption cleanup, synchronously queued behind that
        // save before `selectProfile(_:)` returned, now removes it.
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() == [.delete(profileID: ServerProfile.hosted.id)]
        )
        await tokenStore.resumeOldest()
        await settle()

        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)
        // The switch away is entirely unaffected by the cleanup's own timing.
        #expect(model.sessionState == expectedSignedOut)
    }

    @Test(
        """
        Switching back to a profile whose sign-in was interrupted and cleaned up \
        cannot restore the abandoned token
        """
    )
    func switchingBackAfterInterruptedCleanupDoesNotRestoreToken() async throws {
        let store = FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile])
        let tokenStore = GatedTokenStore()
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "abandoned-token") }
        await tokenStore.waitUntilPending(1)
        model.selectProfile(sampleCustomProfile)

        // Let the abandoned save apply, then let its cleanup delete remove it.
        await tokenStore.resumeOldest()
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest()
        await settle()
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)
        let callsBeforeSwitchingBack = await auth.callOrder.count

        // Switching back to hosted restarts its flow; it must observe no token (the
        // interruption cleanup already removed it) and reach `.signedOut` directly,
        // never silently validating or restoring the abandoned token.
        model.selectProfile(.hosted)
        await model.flowTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        // No new `currentUser` (whoami) call was made restoring into hosted: with no
        // token to read, `restoreToken` never reaches token validation at all.
        #expect(await auth.callOrder.count == callsBeforeSwitchingBack)
    }

    @Test(
        """
        A cleanup failure triggered by switching away preserves the durable tombstone; \
        switching back later retries and resolves it before the profile can ever sign \
        in again with the abandoned token
        """
    )
    func switchAwayCleanupFailurePreservesTombstoneAndIsRetriedOnSwitchBack() async throws {
        let store = FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile])
        let tokenStore = GatedTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "abandoned-token") }
        await tokenStore.waitUntilPending(1)
        model.selectProfile(sampleCustomProfile)

        // Let the abandoned save apply, then let its cleanup delete fail.
        await tokenStore.resumeOldest()
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest(throwing: KeychainError.unhandledStatus(-1))
        await settle()

        #expect(cleanupStore.snapshotPendingIDs() == [ServerProfile.hosted.id])
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "abandoned-token")

        // Switching back to hosted must retry — never skip — the still-pending
        // cleanup before it can trust any token for it.
        model.selectProfile(.hosted)
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() == [.delete(profileID: ServerProfile.hosted.id)]
        )

        // This retried delete succeeds.
        await tokenStore.resumeOldest()
        await model.flowTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)
    }

    @Test(
        """
        Switching profiles while no sign-in/registration is in flight is a pure \
        no-op interruption: no cleanup is enqueued and no token is touched
        """
    )
    func switchingWithNoInFlightAuthOperationEnqueuesNoCleanup() async throws {
        let store = FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile])
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "kept-token"])
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value
        // The hosted profile's own token restores it straight to `.signedIn`; no auth
        // operation is ever in flight.
        #expect(
            model.sessionState ==
                .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )

        model.selectProfile(sampleCustomProfile)
        await model.flowTask?.value

        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
        #expect(await tokenStore.deleteCallCount == 0)
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "kept-token")
    }

    @Test(
        """
        A shared AppModel instance (as every window observes, per the single \
        process-level coordinator architecture) applies the exact same switch-away \
        interruption regardless of which caller triggers the switch
        """
    )
    func sharedModelAppliesSwitchInterruptionConsistently() async throws {
        let store = FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile])
        let tokenStore = GatedTokenStore()
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        // A single, shared `AppModel` — exactly as every `WindowGroup` window is
        // injected the same process-level coordinator in production — observed
        // through two independent local references, standing in for two windows.
        let sharedModel = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await sharedModel.flowTask?.value
        let windowOneModel = sharedModel
        let windowTwoModel = sharedModel

        // "Window one" begins a sign-in.
        windowOneModel.beginAuthOperation(.signingIn) { _ in AuthToken(token: "abandoned-token") }
        await tokenStore.waitUntilPending(1)

        // "Window two" switches the shared coordinator's profile away from under it.
        windowTwoModel.selectProfile(sampleCustomProfile)
        await sharedModel.flowTask?.value
        #expect(
            windowOneModel.sessionState ==
                .signedOut(profile: sampleCustomProfile, compatibility: .legacy)
        )

        await tokenStore.resumeOldest()
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() == [.delete(profileID: ServerProfile.hosted.id)]
        )
        await tokenStore.resumeOldest()
        await settle()

        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)
    }
}
