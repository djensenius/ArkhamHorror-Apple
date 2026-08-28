@testable import ArkhamHorrorShared
import Security
import Testing

/// Token restoration: no token, valid token, unauthorized token deletion, deletion
/// failure, and transient whoami failures that retain the token.
extension AppModelTests {
    @Test("No stored token reaches signedOut without contacting the auth session")
    func noTokenReachesSignedOut() async {
        let auth = ScriptedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth
        )
        await model.flowTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(await auth.callOrder.isEmpty)
    }

    @Test("A valid stored token restores a signed-in session with the typed user")
    func validTokenRestoresSignedIn() async {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "valid-token"])
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth
        )
        await model.flowTask?.value

        let expected = SessionState.signedIn(
            profile: .hosted, compatibility: .legacy, user: .sample
        )
        #expect(model.sessionState == expected)
        #expect(await auth.lastCurrentUserToken == "valid-token")
    }

    @Test("An explicitly unauthorized token is deleted before exposing signedOut")
    func unauthorizedTokenIsDeleted() async throws {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "stale-token"])
        let auth = ScriptedAuthenticating(
            currentUserResult: .failure(AuthenticationError.unauthorized)
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth
        )
        await model.flowTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(await tokenStore.deleteCallCount == 1)
        let remainingToken = try await tokenStore.token(for: ServerProfile.hosted.id)
        #expect(remainingToken == nil)
    }

    @Test("A failed deletion of an unauthorized token surfaces distinctly and is not signedOut")
    func unauthorizedDeletionFailureSurfacesDistinctly() async {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "stale-token"])
        await tokenStore.setDeleteError(KeychainError.unhandledStatus(errSecAuthFailed))
        let auth = ScriptedAuthenticating(
            currentUserResult: .failure(AuthenticationError.unauthorized)
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth
        )
        await model.flowTask?.value

        let expected = SessionUnavailableReason.tokenValidationFailed(
            .tokenStore(.keychain(.unhandledStatus(errSecAuthFailed)))
        )
        #expect(model.sessionState == .unavailable(profile: .hosted, reason: expected))
    }

    @Test("A transient whoami failure retains the token and exposes a retryable state")
    func transientFailureRetainsToken() async throws {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "kept-token"])
        let auth = ScriptedAuthenticating(
            currentUserResult: .failure(AuthenticationError.transportFailure("timed out"))
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth
        )
        await model.flowTask?.value

        let expected = SessionUnavailableReason.tokenValidationFailed(
            .authentication(.transportFailure(""))
        )
        #expect(model.sessionState == .unavailable(profile: .hosted, reason: expected))
        #expect(model.sessionState.isRetryable)
        #expect(await tokenStore.deleteCallCount == 0)
        let remainingToken = try await tokenStore.token(for: ServerProfile.hosted.id)
        #expect(remainingToken == "kept-token")
    }

    @Test("An unexpected whoami error cannot retain its description in session state")
    func unexpectedWhoamiErrorIsSanitized() async {
        let secret = "private-whoami-detail"
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "kept-token"])
        let auth = ScriptedAuthenticating(
            currentUserResult: .failure(SensitiveTestFailure(description: secret))
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth
        )
        await model.flowTask?.value

        let diagnostic: String? = switch model.sessionState {
        case let .unavailable(
            _,
            .tokenValidationFailed(.authentication(.transportFailure(value)))
        ):
            value
        default:
            nil
        }
        #expect(diagnostic == "Unexpected authentication failure.")
        #expect(diagnostic?.contains(secret) == false)
    }
}
