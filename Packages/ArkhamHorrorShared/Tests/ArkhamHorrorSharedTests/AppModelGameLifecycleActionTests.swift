@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Split out of `AppModelGameLifecycleTests.swift` purely by file/type-body length:
/// per-game action (delete/join/open-seats/claim-seat/choose-deck) and typed
/// create-game state-machine coverage for `AppModel`'s game-lifecycle coordination,
/// using the same shared fakes (`GameLifecycleTestSupport.swift`).
@MainActor
@Suite("AppModel — game lifecycle actions")
struct AppModelGameLifecycleActionTests {
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

    // MARK: - Per-game actions: delete

    @Test("deleteGame refreshes the games list on success")
    func deleteGameRefreshesOnSuccess() async {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueueDeleteGameResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.deleteGame(gameID)
        await model.gameLifecycleActionTasks[gameID]?.value
        await model.gameListTask?.value

        #expect(await service.lastDeletedGameID == gameID)
        #expect(model.gameLifecycleActions[gameID] == nil)
        #expect(model.gameListState == .loaded([]))
    }

    @Test("A delete failure records a per-game action failure without touching the games list")
    func deleteGameFailureRecordsActionFailure() async {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueueDeleteGameResult(.failure(GameLifecycleError.unexpectedStatus(404)))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.deleteGame(gameID)
        await model.gameLifecycleActionTasks[gameID]?.value

        #expect(model.gameLifecycleActionFailures[gameID]?.action == .deleting)
        #expect(model.gameLifecycleActionFailures[gameID]?.error == .unexpectedStatus(404))
        #expect(model.gameLifecycleActions[gameID] == nil)
    }

    @Test("A superseding join for the same game discards a slower, stale delete's completion")
    func newerActionSupersedesStaleDeleteCompletion() async {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.setDeleteGameGated(true)
        await service.enqueueJoinGameResult(.success(.game(gameID)))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.deleteGame(gameID)
        await service.waitUntilDeleteGamePending(1)
        #expect(model.gameLifecycleActions[gameID] == .deleting)

        // A newer action for the *same* game supersedes the still-in-flight delete.
        model.joinGame(gameID)
        await model.gameLifecycleActionTasks[gameID]?.value
        await model.gameListTask?.value
        #expect(model.gameLifecycleActions[gameID] == nil)
        #expect(model.gameOpenSeats[gameID] == nil)

        // The stale delete now resolves; it must not resurrect `.deleting` nor record a
        // failure for an action that is no longer current.
        await service.resumeOldestDeleteGame(
            with: .failure(GameLifecycleError.unexpectedStatus(409))
        )
        await Task.yield()
        await Task.yield()
        #expect(model.gameLifecycleActions[gameID] == nil)
        #expect(model.gameLifecycleActionFailures[gameID] == nil)
    }

    @Test("Actions on independent games proceed concurrently without interfering")
    func independentGamesActionsAreIndependent() async {
        let service = ScriptedGameLifecycleService()
        let deletingGameID = GameID(UUID())
        let joiningGameID = GameID(UUID())
        await service.setDeleteGameGated(true)
        await service.enqueueJoinGameResult(.success(.game(joiningGameID)))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.deleteGame(deletingGameID)
        await service.waitUntilDeleteGamePending(1)
        model.joinGame(joiningGameID)
        await model.gameLifecycleActionTasks[joiningGameID]?.value

        #expect(model.gameLifecycleActions[deletingGameID] == .deleting)
        #expect(model.gameLifecycleActions[joiningGameID] == nil)

        await service.resumeOldestDeleteGame(with: .success(()))
        await model.gameLifecycleActionTasks[deletingGameID]?.value
        #expect(model.gameLifecycleActions[deletingGameID] == nil)
    }

    // MARK: - Pending join / open seats / claim seat / choose deck

    @Test("joinGame reports .malformedPayload for an unsupported response envelope")
    func joinGameSuccessAndUnsupportedEnvelope() async {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueueJoinGameResult(.success(.unsupported))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.joinGame(gameID)
        await model.gameLifecycleActionTasks[gameID]?.value

        #expect(model.gameLifecycleActionFailures[gameID]?.action == .joining)
        #expect(model.gameLifecycleActionFailures[gameID]?.error == .malformedPayload)
    }

    @Test("loadOpenSeats populates gameOpenSeats on success")
    func loadOpenSeatsPopulatesState() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seats: OpenSeats = try [CardCode("c01001"), CardCode("c01002")]
        await service.enqueueOpenSeatsResult(.success(seats))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.loadOpenSeats(for: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value

        #expect(model.gameOpenSeats[gameID] == seats)
        #expect(model.gameLifecycleActions[gameID] == nil)
    }

    @Test("claimSeat converts the open-seat CardCode into the claim request's InvestigatorCode")
    func claimSeatConvertsInvestigatorCode() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueueClaimSeatResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        try model.claimSeat(CardCode("c01001"), in: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value
        await model.gameListTask?.value

        let sentRequest = await service.lastClaimSeatRequest
        #expect(sentRequest?.investigatorId.rawValue == "c01001")
        #expect(model.gameListState == .loaded([]))
    }

    @Test("claimSeat clears any previously loaded open-seats snapshot for that game on success")
    func claimSeatClearsStaleOpenSeats() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        try await service.enqueueOpenSeatsResult(.success([CardCode("c01001")]))
        await service.enqueueClaimSeatResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.loadOpenSeats(for: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value
        #expect(model.gameOpenSeats[gameID] != nil)

        try model.claimSeat(CardCode("c01001"), in: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value
        await model.gameListTask?.value

        #expect(model.gameOpenSeats[gameID] == nil)
    }

    @Test("continueWithoutUpgrading sends a ChooseDeckRequest with no deck source")
    func chooseDeckContinueWithoutUpgrading() async {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueueChooseDeckResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.continueWithoutUpgrading(investigatorId: "01001", in: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value
        await model.gameListTask?.value

        let sentRequest = await service.lastChooseDeckRequest
        #expect(sentRequest?.investigatorId.rawValue == "01001")
        #expect(sentRequest?.deckUrl == nil)
        #expect(sentRequest?.deckList == nil)
        #expect(model.gameListState == .loaded([]))
    }

    // MARK: - createGame (typed operation; no polished create UI)

    @Test("createGame returns the created game's ID and refreshes the list")
    func createGameReturnsIDAndRefreshes() async throws {
        let service = ScriptedGameLifecycleService()
        let createdID = GameID(UUID())
        await service.enqueueCreateGameResult(.success(.game(createdID)))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let request = try CreateGameRequest(
            deckIds: [],
            playerCount: 1,
            campaignOrScenario: CampaignOrScenario(campaignId: nil, scenarioId: "01104"),
            difficulty: .easy,
            campaignName: "Test",
            multiplayerVariant: .solo,
            includeTarotReadings: false,
            options: [],
            strictAsIfAt: .absent,
            asIfRuling: .absent,
            ultimatumsAndBoons: .absent,
            achievementsEnabled: .absent
        )
        let returnedID = try await model.createGame(request)
        await model.gameListTask?.value

        #expect(returnedID == createdID)
        #expect(model.gameListState == .loaded([]))
    }

    @Test("createGame throws sessionExpired when not currently signed in")
    func createGameRequiresSignedIn() async throws {
        let service = ScriptedGameLifecycleService()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: service
        )
        await model.flowTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        let request = try CreateGameRequest(
            deckIds: [], playerCount: 1,
            campaignOrScenario: CampaignOrScenario(campaignId: nil, scenarioId: "01104"),
            difficulty: .easy, campaignName: "Test", multiplayerVariant: .solo,
            includeTarotReadings: false, options: [],
            strictAsIfAt: .absent, asIfRuling: .absent, ultimatumsAndBoons: .absent,
            achievementsEnabled: .absent
        )
        await #expect(throws: GameLifecycleError.sessionExpired) {
            try await model.createGame(request)
        }
    }

    // MARK: - No secret leakage

    @Test("A game-lifecycle action failure's message never contains the session token")
    func actionFailureMessageDoesNotLeakToken() async {
        let secretToken = "top-secret-lifecycle-token"
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueueDeleteGameResult(
            .failure(GameLifecycleError.transportFailure(secretToken))
        )
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: service, token: secretToken
        )

        model.deleteGame(gameID)
        await model.gameLifecycleActionTasks[gameID]?.value

        let failure = model.gameLifecycleActionFailures[gameID]
        #expect(failure != nil)
        if let failure {
            #expect(!failure.error.message.contains(secretToken))
        }
    }
}
