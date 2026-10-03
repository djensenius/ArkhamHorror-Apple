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

    @Test("stale lobby detail cleanup cannot clear a replacement load")
    func staleLobbyDetailCleanupDoesNotClearReplacementTask() async {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.setGetGameGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.loadLobbyDetailsIfNeeded(for: gameID)
        await service.waitUntilGetGamePending(1)
        model.generation += 1
        model.resetGameLifecycleState()
        model.loadLobbyDetailsIfNeeded(for: gameID)
        await service.waitUntilGetGamePending(2)

        await service.resumeOldestGetGame(with: .success(getGameEnvelope(gameID: gameID)))
        let replacementTask = model.gameLobbyDetailTasks[gameID]
        #expect(replacementTask != nil)
        #expect(model.gameLobbyDetailTaskIDs[gameID] != nil)

        await service.resumeNewestGetGame(with: .success(getGameEnvelope(gameID: gameID)))
        await replacementTask?.value
        #expect(model.gameLobbyDetailTasks[gameID] == nil)
        #expect(model.gameLobbyDetailTaskIDs[gameID] == nil)
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
