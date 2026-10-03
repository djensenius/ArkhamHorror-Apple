@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — game invite lobby detail review fixes")
struct AppModelGameInviteLobbyDetailReviewTests {
    private func getGameEnvelope(
        gameID _: GameID,
        playerID: PlayerID? = PlayerID(UUID()),
        playerCount: Int = 2
    ) -> GetGameEnvelope {
        GetGameEnvelope(
            playerID: playerID,
            multiplayerMode: .withFriends,
            game: BoardTestFixtures.snapshot(playerCount: playerCount),
            eventID: nil
        )
    }

    private func gameSummary(id: GameID) -> GameSummary {
        GameSummary(
            id: id,
            scenario: nil,
            campaign: nil,
            gameState: .pending([PlayerID(UUID())]),
            name: "Sample",
            investigators: [],
            otherInvestigators: [],
            multiplayerVariant: .withFriends,
            hasOpenSeats: true
        )
    }

    @Test("stale lobby detail cleanup cannot clear a replacement load")
    func staleLobbyDetailCleanupDoesNotClearReplacementTask() async {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.setGetGameGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.loadLobbyDetailsIfNeeded(for: gameID)
        await service.waitUntilGetGamePending(1)
        let staleTask = model.gameLobbyDetailTasks[gameID]
        #expect(staleTask != nil)
        model.generation += 1
        model.resetGameLifecycleState()
        model.loadLobbyDetailsIfNeeded(for: gameID)
        await service.waitUntilGetGamePending(2)

        await service.resumeOldestGetGame(with: .success(getGameEnvelope(gameID: gameID)))
        await staleTask?.value
        let replacementTask = model.gameLobbyDetailTasks[gameID]
        #expect(replacementTask != nil)
        #expect(model.gameLobbyDetailTaskIDs[gameID] != nil)

        await service.resumeNewestGetGame(with: .success(getGameEnvelope(gameID: gameID)))
        await replacementTask?.value
        #expect(model.gameLobbyDetailTasks[gameID] == nil)
        #expect(model.gameLobbyDetailTaskIDs[gameID] == nil)
    }

    @Test("failed viewer membership loads expose retry and reload successfully")
    func failedViewerMembershipLoadCanRetry() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let failure = GameLifecycleError.unexpectedStatus(500)
        await service.enqueueGetGameResult(.failure(failure))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.loadLobbyDetailsIfNeeded(for: gameID)
        var detailTask = try #require(model.gameLobbyDetailTasks[gameID])
        await detailTask.value

        let game = gameSummary(id: gameID)
        let seat = try CardCode("c01001")
        model.gameListState = .loaded([.game(game)])
        model.gameOpenSeats[gameID] = [seat]
        let view = GameLobbyView(model: model, gameID: gameID)
        _ = view.body
        #expect(model.gameLobbyViewerSeatFailures[gameID] == failure)
        #expect(view.viewerSeatStatus(in: game) == .failed(failure))
        #expect(!view.showsClaimSeatButtons(for: game, openSeats: [seat]))
        #expect(
            view.openSeatsStatusText(for: game, openSeats: [seat])
                == "Could not check whether you already have a seat: \(failure.message)"
        )

        await service.enqueueGetGameResult(.success(getGameEnvelope(gameID: gameID)))
        view.retryLobbySeatStatus()
        detailTask = try #require(model.gameLobbyDetailTasks[gameID])
        await detailTask.value

        #expect(model.gameLobbyViewerSeatFailures[gameID] == nil)
        #expect(model.gameLobbyViewerHasSeats[gameID] == true)
        #expect(!view.showsClaimSeatButtons(for: game, openSeats: [seat]))
        #expect(await service.callOrder == ["getGame", "getGame"])
    }

    @Test("cached player counts do not skip the viewer-specific seat lookup")
    func cachedPlayerCountDoesNotSkipViewerSeatLookup() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueueGetGameResult(.failure(GameLifecycleError.unexpectedStatus(404)))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        model.gameLobbyPlayerCounts[gameID] = 4

        model.loadLobbyDetailsIfNeeded(for: gameID)
        let detailTask = try #require(model.gameLobbyDetailTasks[gameID])
        await detailTask.value

        #expect(await service.callOrder == ["getGame"])
        #expect(model.gameLobbyPlayerCounts[gameID] == 4)
        #expect(model.gameLobbyViewerHasSeats[gameID] == false)
    }
}
