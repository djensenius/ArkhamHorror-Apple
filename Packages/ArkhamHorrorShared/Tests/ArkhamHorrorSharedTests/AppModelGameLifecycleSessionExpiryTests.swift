@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic coverage for the game-lifecycle 401 (`GameLifecycleError.sessionExpired`)
/// handling race identified in review: a per-game action's (or `createGame`'s) stale
/// completion must never be able to authorize deleting a *different*, newer session's
/// token, and cancellation observed after a response was already in flight must never
/// be misreported as an actionable failure.
@MainActor
@Suite("AppModel — game lifecycle session expiry")
struct AppModelGameLifecycleSessionExpiryTests {
    private func makeSignedInModel(
        service: ScriptedGameLifecycleService,
        initialToken: String,
        reauthenticateWithToken: String
    ) -> (model: AppModel, tokenStore: FakeTokenStore) {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: initialToken])
        let auth = ScriptedAuthenticating(
            authenticateResult: .success(AuthToken(token: reauthenticateWithToken)),
            currentUserResult: .success(.sample)
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: service
        )
        return (model, tokenStore)
    }

    @Test(
        """
        A stale action's 401, arriving after sign-out and a newer sign-in to the same \
        profile, cannot delete the newer session's token or disturb its state
        """
    )
    func staleActionSessionExpiryCannotDeleteNewerToken() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.setDeleteGameGated(true)
        let (model, tokenStore) = makeSignedInModel(
            service: service, initialToken: "t1-token", reauthenticateWithToken: "t2-token"
        )
        await model.flowTask?.value
        #expect(
            model.sessionState == .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )

        // T1: a delete for `gameID` begins while signed in with the original token.
        model.deleteGame(gameID)
        await service.waitUntilDeleteGamePending(1)
        // Captured before sign-out clears `gameLifecycleActionTasks` (as part of
        // `resetGameLifecycleState()`), so this test can deterministically await T1's
        // full completion later -- including every awaited step inside its own
        // session-expiry handling -- instead of guessing with `Task.yield()`.
        let staleDeleteTask = model.gameLifecycleActionTasks[gameID]

        // Sign out, then sign back in to the *same* profile with a fresh token (T2).
        model.signOut()
        await model.operationTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        model.signIn(AuthenticationCredentials(email: "a@example.com", password: "pw"))
        await model.operationTask?.value
        #expect(
            model.sessionState == .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )
        let tokenAfterSignIn = try await tokenStore.token(for: ServerProfile.hosted.id)
        #expect(tokenAfterSignIn == "t2-token")

        // T1's now-stale delete finally resolves with a 401.
        await service.resumeOldestDeleteGame(with: .failure(GameLifecycleError.sessionExpired))
        await staleDeleteTask?.value

        // The newer session (T2) must be completely undisturbed: still signed in, and
        // its own freshly saved token must not have been deleted by T1's stale 401.
        #expect(
            model.sessionState == .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )
        let tokenAfterStaleRace = try await tokenStore.token(for: ServerProfile.hosted.id)
        #expect(tokenAfterStaleRace == "t2-token")
    }

    @Test("A still-current action's 401 does delete its token and transitions to signedOut")
    func currentActionSessionExpiryStillSignsOut() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueueDeleteGameResult(.failure(GameLifecycleError.sessionExpired))
        let (model, tokenStore) = makeSignedInModel(
            service: service, initialToken: "t1-token", reauthenticateWithToken: "t2-token"
        )
        await model.flowTask?.value

        model.deleteGame(gameID)
        await model.gameLifecycleActionTasks[gameID]?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        let tokenAfter = try await tokenStore.token(for: ServerProfile.hosted.id)
        #expect(tokenAfter == nil)
        #expect(model.gameListState == .idle)
    }

    @Test(
        """
        Cancellation observed after the response is in flight is never recorded as a \
        failure, but does clear the in-flight marker so the row is never stuck
        """
    )
    func cancellationAfterResponseIsNotRecordedAsFailure() async {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueueDeleteGameResult(.failure(CancellationError()))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.deleteGame(gameID)
        await model.gameLifecycleActionTasks[gameID]?.value

        // Cancellation must be silently swallowed (no failure recorded), but since
        // this attempt is still `gameID`'s current one (nothing superseded it), the
        // in-flight marker must be cleared back to `nil` -- never left stuck at
        // `.deleting` forever with the row's controls permanently disabled and no
        // way to retry.
        #expect(model.gameLifecycleActions[gameID] == nil)
        #expect(model.gameLifecycleActionFailures[gameID] == nil)
        #expect(model.sessionState.isSignedIn)
    }

    @Test(
        "A superseded action's cancellation never clears a newer, still-pending action's own marker"
    )
    func cancellationOfSupersededActionDoesNotClearNewerPendingMarker() async {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.setDeleteGameGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        // T1: begins deleting `gameID`.
        model.deleteGame(gameID)
        await service.waitUntilDeleteGamePending(1)
        let staleDeleteTask = model.gameLifecycleActionTasks[gameID]

        // T2: a newer delete for the *same* game supersedes T1, which is still gated
        // (pending) at this point.
        model.deleteGame(gameID)
        await service.waitUntilDeleteGamePending(2)
        #expect(model.gameLifecycleActions[gameID] == .deleting)

        // T1's now-stale call observes cancellation.
        await service.resumeOldestDeleteGame(with: .failure(CancellationError()))
        await staleDeleteTask?.value

        // T2 is still genuinely in flight; T1's stale cancellation must not have
        // cleared T2's own marker prematurely.
        #expect(model.gameLifecycleActions[gameID] == .deleting)
        #expect(model.gameLifecycleActionFailures[gameID] == nil)
    }
}

private extension SessionState {
    var isSignedIn: Bool {
        if case .signedIn = self {
            true
        } else {
            false
        }
    }
}
