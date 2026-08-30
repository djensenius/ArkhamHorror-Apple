@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic state-machine coverage for `AppModel`'s game-lifecycle/lobby
/// coordination (`AppModel+GameLifecycle.swift`), backed entirely by
/// ``ScriptedGameLifecycleService`` and the existing in-memory `AppModel` fakes --
/// never real network I/O.
@MainActor
@Suite("AppModel — game lifecycle")
struct AppModelGameLifecycleTests {
    private func sampleGame(id: UUID = UUID(), name: String = "Sample") -> GameSummary {
        GameSummary(
            id: GameID(id),
            scenario: nil,
            campaign: nil,
            gameState: .active,
            name: name,
            investigators: [],
            otherInvestigators: [],
            multiplayerVariant: .solo,
            hasOpenSeats: false
        )
    }

    // MARK: - Initial load / refresh

    @Test("refreshGames transitions idle -> loading -> loaded, using the current token")
    func initialLoadPopulatesGameList() async {
        let service = ScriptedGameLifecycleService()
        let games: GameList = [.game(sampleGame())]
        await service.enqueueListGamesResult(.success(games))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service, token: "tok-1")

        #expect(model.gameListState == .idle)
        model.refreshGames()
        await model.gameListTask?.value

        #expect(model.gameListState == .loaded(games))
        #expect(await service.lastToken == "tok-1")
    }

    @Test("A refresh failure preserves nil previous content and is retryable")
    func initialLoadFailurePreservesNilPrevious() async {
        let service = ScriptedGameLifecycleService()
        await service.enqueueListGamesResult(.failure(GameLifecycleError.unexpectedStatus(500)))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.refreshGames()
        await model.gameListTask?.value

        #expect(model.gameListState == .failed(.unexpectedStatus(500), previous: nil))
    }

    @Test("A refresh failure after a prior success keeps the prior content visible")
    func refreshFailureKeepsPriorContentVisible() async {
        let service = ScriptedGameLifecycleService()
        let games: GameList = [.game(sampleGame())]
        await service.enqueueListGamesResult(.success(games))
        await service.enqueueListGamesResult(.failure(GameLifecycleError.transportFailure("x")))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.refreshGames()
        await model.gameListTask?.value
        #expect(model.gameListState == .loaded(games))

        model.refreshGames()
        await model.gameListTask?.value
        #expect(model.gameListState == .failed(.transportFailure(""), previous: games))
        #expect(model.gameListState.games == games)
    }

    // MARK: - Overlapping / reordered responses

    @Test(
        "A newer refresh's result wins even when the older refresh's response arrives later"
    )
    func reorderedRefreshResponsesNewerWins() async {
        let service = ScriptedGameLifecycleService()
        await service.setListGamesGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.refreshGames()
        await service.waitUntilListGamesPending(1)
        model.refreshGames()
        await service.waitUntilListGamesPending(2)

        let staleGames: GameList = [.game(sampleGame(name: "Stale"))]
        let freshGames: GameList = [.game(sampleGame(name: "Fresh"))]
        // The newer (second) refresh's response arrives and resolves first...
        await service.resumeNewestListGames(with: .success(freshGames))
        await model.gameListTask?.value
        #expect(model.gameListState == .loaded(freshGames))

        // ...then the older (first) refresh's now-stale response arrives late. It must
        // not overwrite the newer, already-applied result.
        await service.resumeOldestListGames(with: .success(staleGames))
        // Give the (already-superseded, generation-guarded) completion a chance to run.
        await Task.yield()
        await Task.yield()
        #expect(model.gameListState == .loaded(freshGames))
    }

    @Test("Rapidly restarting a refresh never lets a stale generation mutate state")
    func rapidRefreshRestartIsGenerationGuarded() async {
        let service = ScriptedGameLifecycleService()
        await service.setListGamesGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.refreshGames()
        await service.waitUntilListGamesPending(1)
        model.refreshGames()
        await service.waitUntilListGamesPending(2)
        model.refreshGames()
        await service.waitUntilListGamesPending(3)

        let finalGames: GameList = [.game(sampleGame(name: "Final"))]
        await service.resumeNewestListGames(with: .success(finalGames))
        await model.gameListTask?.value
        #expect(model.gameListState == .loaded(finalGames))

        // The two superseded refreshes' late responses must not matter.
        await service.resumeOldestListGames(with: .success([.game(sampleGame(name: "Oldest"))]))
        await service.resumeOldestListGames(with: .success([.game(sampleGame(name: "Middle"))]))
        await Task.yield()
        await Task.yield()
        #expect(model.gameListState == .loaded(finalGames))
    }

    // MARK: - Sign-out / profile switch / 401 invalidation

    @Test("Sign-out resets gameListState and every per-game action/open-seat entry")
    func signOutClearsGameLifecycleState() async {
        let service = ScriptedGameLifecycleService()
        let games: GameList = [.game(sampleGame())]
        await service.enqueueListGamesResult(.success(games))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        model.refreshGames()
        await model.gameListTask?.value
        #expect(model.gameListState == .loaded(games))

        model.signOut()
        await model.operationTask?.value

        #expect(model.gameListState == .idle)
        #expect(model.gameLifecycleActions.isEmpty)
        #expect(model.gameLifecycleActionFailures.isEmpty)
        #expect(model.gameOpenSeats.isEmpty)
    }

    @Test("A refresh started before sign-out cannot populate the list after sign-out completes")
    func staleRefreshCannotSurviveSignOut() async {
        let service = ScriptedGameLifecycleService()
        await service.setListGamesGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.refreshGames()
        await service.waitUntilListGamesPending(1)

        model.signOut()
        await model.operationTask?.value
        #expect(model.gameListState == .idle)

        // The refresh that was in flight when sign-out began now resolves.
        await service.resumeOldestListGames(with: .success([.game(sampleGame())]))
        await Task.yield()
        await Task.yield()

        #expect(model.gameListState == .idle)
    }

    @Test("An HTTP 401 from listGames deletes the token and signs out without stale content")
    func sessionExpiryFromListGamesSignsOut() async throws {
        let service = ScriptedGameLifecycleService()
        let games: GameList = [.game(sampleGame())]
        await service.enqueueListGamesResult(.success(games))
        await service.enqueueListGamesResult(.failure(GameLifecycleError.sessionExpired))
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "expiring-token"])
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: service
        )
        await model.flowTask?.value
        model.refreshGames()
        await model.gameListTask?.value
        #expect(model.gameListState == .loaded(games))

        model.refreshGames()
        await model.gameListTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(model.gameListState == .idle)
        let remainingToken = try await tokenStore.token(for: ServerProfile.hosted.id)
        #expect(remainingToken == nil)
    }

    @Test(
        """
        A missing token for a still-current refresh routes through session-expiry \
        and signs out, rather than leaving the app on the signed-in route with no \
        usable token
        """
    )
    func noTokenFromListGamesSignsOut() async throws {
        let service = ScriptedGameLifecycleService()
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "token"])
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: service
        )
        await model.flowTask?.value
        #expect(
            model.sessionState == .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )

        // Simulates a concurrent event (e.g. a sign-out or storage reset) having
        // already durably deleted the token before `sessionState` observed it.
        try await tokenStore.deleteToken(for: ServerProfile.hosted.id)

        model.refreshGames()
        await model.gameListTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(model.gameListState == .idle)
    }

    @Test("Switching profiles clears the previous profile's loaded games list")
    func profileSwitchClearsGameLifecycleState() async {
        let service = ScriptedGameLifecycleService()
        let games: GameList = [.game(sampleGame())]
        await service.enqueueListGamesResult(.success(games))
        let profileStore = FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile])
        let model = AppModel(
            profileStore: profileStore,
            tokenStore: FakeTokenStore(tokens: [ServerProfile.hosted.id: "hosted-token"]),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: service
        )
        await model.flowTask?.value
        model.refreshGames()
        await model.gameListTask?.value
        #expect(model.gameListState == .loaded(games))

        model.selectProfile(sampleCustomProfile)
        await model.flowTask?.value

        #expect(model.gameListState == .idle)
        #expect(model.selectedProfile == sampleCustomProfile)
    }
}
