@testable import ArkhamHorrorShared
import Testing

/// Profile switching, stale completions, retry, and credential retention checks.
extension AppModelTests {
    @Test("Switching profiles persists the selection and restarts the flow")
    func switchingProfilesPersistsAndRestarts() async {
        let store = FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile])
        let model = AppModel(
            profileStore: store,
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating()
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
            authenticationSession: ScriptedAuthenticating()
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
            authenticationSession: ScriptedAuthenticating()
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
            authenticationSession: auth
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
}
