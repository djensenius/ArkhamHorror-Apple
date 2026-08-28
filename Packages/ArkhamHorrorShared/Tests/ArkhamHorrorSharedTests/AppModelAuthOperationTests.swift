@testable import ArkhamHorrorShared
import Security
import Testing

/// Sign-in and registration: validate-before-save ordering, save failure, cancellation,
/// and sign-out (successful deletion transitions to signedOut; a deletion failure
/// leaves the session signed in and surfaces a distinct operation error).
extension AppModelTests {
    @Test("Authentication operation messages do not overstate the failure cause")
    func authenticationOperationMessagesAreNeutral() {
        #expect(
            SessionOperationFailure.authentication(.unauthorized).message ==
                "Authentication was rejected. Check your details and try again."
        )
        #expect(
            SessionOperationFailure.authentication(.malformedPayload).message ==
                "Could not complete authentication. Try again."
        )
    }

    @Test("Sign-in validates the issued token via whoami before saving it")
    func signInValidatesBeforeSaving() async {
        let tokenStore = FakeTokenStore()
        let auth = ScriptedAuthenticating(
            authenticateResult: .success(AuthToken(token: "new-token")),
            currentUserResult: .success(.sample)
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        model.signIn(AuthenticationCredentials(email: "a@example.com", password: "secret-pw"))
        await model.operationTask?.value

        #expect(await auth.callOrder == ["authenticate", "currentUser"])
        #expect(await tokenStore.saveCallCount == 1)
        #expect(await tokenStore.lastSavedToken == "new-token")
        let expected = SessionState.signedIn(
            profile: .hosted, compatibility: .legacy, user: .sample
        )
        #expect(model.sessionState == expected)
        #expect(model.operation == .idle)
        #expect(model.operationFailure == nil)
    }

    @Test("Registration validates the issued token via whoami before saving it")
    func registrationValidatesBeforeSaving() async {
        let tokenStore = FakeTokenStore()
        let auth = ScriptedAuthenticating(
            registerResult: .success(AuthToken(token: "registered-token")),
            currentUserResult: .success(.sample)
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        model.register(
            RegistrationDetails(email: "a@example.com", username: "ashcan", password: "secret-pw")
        )
        await model.operationTask?.value

        #expect(await auth.callOrder == ["register", "currentUser"])
        #expect(await tokenStore.saveCallCount == 1)
        let expected = SessionState.signedIn(
            profile: .hosted, compatibility: .legacy, user: .sample
        )
        #expect(model.sessionState == expected)
    }

    @Test("A save failure after validation does not expose signedIn")
    func saveFailureDoesNotExposeSignedIn() async {
        let tokenStore = FakeTokenStore()
        await tokenStore.setSaveError(KeychainError.unhandledStatus(errSecAuthFailed))
        let auth = ScriptedAuthenticating(
            authenticateResult: .success(AuthToken(token: "new-token")),
            currentUserResult: .success(.sample)
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        model.signIn(AuthenticationCredentials(email: "a@example.com", password: "secret-pw"))
        await model.operationTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        let expectedFailure = SessionOperationFailure.tokenStore(
            .keychain(.unhandledStatus(errSecAuthFailed))
        )
        #expect(model.operationFailure == expectedFailure)
        #expect(model.operation == .idle)
    }

    @Test("Sign-in cancellation clears the in-flight operation without an error")
    func signInCancellationIsNotAnError() async {
        let auth = ScriptedAuthenticating(authenticateResult: .failure(CancellationError()))
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        model.signIn(AuthenticationCredentials(email: "a@example.com", password: "secret-pw"))
        await model.operationTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(model.operation == .idle)
        #expect(model.operationFailure == nil)
    }

    @Test("An unexpected sign-in error cannot retain its description in operation state")
    func unexpectedSignInErrorIsSanitized() async {
        let secret = "private-sign-in-detail"
        let auth = ScriptedAuthenticating(
            authenticateResult: .failure(SensitiveTestFailure(description: secret))
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        model.signIn(AuthenticationCredentials(email: "a@example.com", password: "secret-pw"))
        await model.operationTask?.value

        let diagnostic: String? = switch model.operationFailure {
        case let .authentication(.transportFailure(value)):
            value
        default:
            nil
        }
        #expect(diagnostic == "Unexpected authentication failure.")
        #expect(diagnostic?.contains(secret) == false)
    }

    // MARK: - Explicit cancellation (`cancelAuthOperation`)

    @Test("Cancelling sign-in stops a slow whoami from later signing in or saving a token")
    func cancelAuthOperationPreventsLateSignIn() async {
        let tokenStore = FakeTokenStore()
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

        // Uses `beginAuthOperation` directly with a custom, instantly-issued token —
        // the same production entry point `signIn`/`register` call — so the slow step
        // under test is the whoami validation, exactly like `GatedAuthenticating`'s
        // other race coverage.
        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        #expect(model.operation == .signingIn)

        // Captured before `cancelAuthOperation()` (which unconditionally nils
        // `operationTask`), so this test can deterministically await the stale
        // operation's own completion below instead of inferring scheduler progress
        // with a fixed number of yields. `operationTask`'s body runs
        // `beginAuthOperationAfterResolvingCleanup`/`performAuthOperation` end to end
        // with no further unawaited indirection, so awaiting it fully waits for any
        // save attempt this stale operation could still make.
        let staleOperation = model.operationTask
        model.cancelAuthOperation()

        #expect(model.operation == .idle)
        #expect(model.operationFailure == nil)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        // The task handle is released promptly, not retained past cancellation.
        #expect(model.operationTask == nil)

        // The slow whoami now resolves successfully, out of order, well after
        // cancellation.
        await auth.resumeOldest(with: .success(.sample))
        await staleOperation?.value

        // Cancellation must have stopped this from ever signing in or saving a token,
        // even though the underlying dependency ignored the task cancellation.
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(await tokenStore.saveCallCount == 0)
    }

    @Test("Cancelling a registration stops it from later registering or saving its token")
    func cancelAuthOperationPreventsLateRegistration() async {
        let tokenStore = FakeTokenStore()
        let auth = GatedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        model.beginAuthOperation(.registering) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        #expect(model.operation == .registering)

        // See the identical rationale in `cancelAuthOperationPreventsLateSignIn`.
        let staleOperation = model.operationTask
        model.cancelAuthOperation()
        #expect(model.operation == .idle)
        #expect(model.operationTask == nil)

        await auth.resumeOldest(with: .success(.sample))
        await staleOperation?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(await tokenStore.saveCallCount == 0)
    }

    @Test("cancelAuthOperation is a no-op after success, so an idempotent dismissal cannot undo it")
    func cancelAuthOperationIsNoOpAfterSuccess() async throws {
        let tokenStore = FakeTokenStore()
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        await model.operationTask?.value
        let signedIn = SessionState.signedIn(
            profile: .hosted, compatibility: .legacy, user: .sample
        )
        #expect(model.sessionState == signedIn)

        // A late, idempotent view-disappearance callback must not undo the
        // already-successful sign-in.
        model.cancelAuthOperation()

        #expect(model.sessionState == signedIn)
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "issued-token")
    }
}

/// Sign-out: successful deletion transitions to signedOut; a deletion failure leaves
/// the session signed in and surfaces a distinct operation error.
extension AppModelTests {
    @Test("Sign-out deletes the selected profile's token before exposing signedOut")
    func signOutSucceeds() async {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "existing-token"])
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        let signedIn = SessionState.signedIn(
            profile: .hosted, compatibility: .legacy, user: .sample
        )
        #expect(model.sessionState == signedIn)

        model.signOut()
        await model.operationTask?.value

        #expect(await tokenStore.deleteCallCount == 1)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(model.operationFailure == nil)
    }

    @Test("A sign-out deletion failure leaves the session signed in and surfaces an error")
    func signOutFailureRemainsSignedIn() async {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "existing-token"])
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        await tokenStore.setDeleteError(KeychainError.unhandledStatus(errSecAuthFailed))

        model.signOut()
        await model.operationTask?.value

        let signedIn = SessionState.signedIn(
            profile: .hosted, compatibility: .legacy, user: .sample
        )
        #expect(model.sessionState == signedIn)
        let expectedFailure = SessionOperationFailure.tokenStore(
            .keychain(.unhandledStatus(errSecAuthFailed))
        )
        #expect(model.operationFailure == expectedFailure)
    }
}
