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

    @Test("cancelled current viewer membership load exposes retry state")
    func cancelledCurrentViewerMembershipLoadCanRetry() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let failure = GameLifecycleError.transportFailure("Lobby membership unavailable")
        await service.enqueueGetGameResult(.failure(CancellationError()))
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
        #expect(model.gameLobbyViewerHasSeats[gameID] == nil)
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

    @Test("superseded viewer membership cancellation stays silent")
    func supersededViewerMembershipCancellationDoesNotPublishFailure() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.setGetGameGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.loadLobbyDetailsIfNeeded(for: gameID)
        await service.waitUntilGetGamePending(1)
        let staleTask = try #require(model.gameLobbyDetailTasks[gameID])
        model.reloadLobbyViewerSeatStatus(for: gameID)
        await service.waitUntilGetGamePending(2)
        let replacementTask = try #require(model.gameLobbyDetailTasks[gameID])

        await service.resumeOldestGetGame(with: .failure(CancellationError()))
        await staleTask.value

        #expect(model.gameLobbyViewerHasSeats[gameID] == nil)
        #expect(model.gameLobbyViewerSeatFailures[gameID] == nil)
        #expect(model.gameLobbyDetailTasks[gameID] != nil)

        await service.resumeNewestGetGame(with: .success(getGameEnvelope(gameID: gameID)))
        await replacementTask.value

        #expect(model.gameLobbyViewerHasSeats[gameID] == true)
        #expect(model.gameLobbyViewerSeatFailures[gameID] == nil)
        #expect(await service.callOrder == ["getGame", "getGame"])
    }

    @Test("stale detail task cleanup is owned by task UUID even after session changes")
    func staleDetailCleanupClearsByTaskIDAfterSessionChange() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.setGetGameGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.loadLobbyDetailsIfNeeded(for: gameID)
        await service.waitUntilGetGamePending(1)
        let staleTask = try #require(model.gameLobbyDetailTasks[gameID])
        model.generation += 1
        await service.resumeOldestGetGame(with: .success(getGameEnvelope(gameID: gameID)))
        await staleTask.value

        #expect(model.gameLobbyDetailTasks[gameID] == nil)
        #expect(model.gameLobbyDetailTaskIDs[gameID] == nil)

        model.loadLobbyDetailsIfNeeded(for: gameID)
        await service.waitUntilGetGamePending(1)
        let replacementTask = try #require(model.gameLobbyDetailTasks[gameID])
        await service.resumeOldestGetGame(with: .success(getGameEnvelope(gameID: gameID)))
        await replacementTask.value

        #expect(model.gameLobbyViewerHasSeats[gameID] == true)
        #expect(model.gameLobbyDetailTasks[gameID] == nil)
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

    @Test("reentering a lobby re-fetches viewer membership instead of reusing the old answer")
    func reenteringLobbyRechecksViewerMembership() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueueGetGameResult(.success(
            getGameEnvelope(gameID: gameID, playerID: nil, playerCount: 4)
        ))
        await service.enqueueGetGameResult(.success(getGameEnvelope(gameID: gameID)))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.loadLobbyDetailsIfNeeded(for: gameID)
        var detailTask = try #require(model.gameLobbyDetailTasks[gameID])
        await detailTask.value
        #expect(model.gameLobbyPlayerCounts[gameID] == 4)
        #expect(model.gameLobbyViewerHasSeats[gameID] == false)

        model.loadLobbyDetailsIfNeeded(for: gameID)
        #expect(model.gameLobbyViewerHasSeats[gameID] == nil)
        detailTask = try #require(model.gameLobbyDetailTasks[gameID])
        await detailTask.value

        #expect(await service.callOrder == ["getGame", "getGame"])
        #expect(model.gameLobbyViewerHasSeats[gameID] == true)
    }

    @Test("superseded lobby detail results cannot overwrite their replacement")
    func supersededLobbyDetailResultCannotOverwriteReplacement() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.setGetGameGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.loadLobbyDetailsIfNeeded(for: gameID)
        await service.waitUntilGetGamePending(1)
        let staleTask = try #require(model.gameLobbyDetailTasks[gameID])
        model.reloadLobbyViewerSeatStatus(for: gameID)
        await service.waitUntilGetGamePending(2)
        let replacementTask = try #require(model.gameLobbyDetailTasks[gameID])

        await service.resumeNewestGetGame(with: .success(getGameEnvelope(gameID: gameID)))
        await replacementTask.value
        #expect(model.gameLobbyViewerHasSeats[gameID] == true)

        await service.resumeOldestGetGame(with: .failure(GameLifecycleError.unexpectedStatus(404)))
        await staleTask.value

        #expect(model.gameLobbyViewerHasSeats[gameID] == true)
        #expect(model.gameLobbyViewerSeatFailures[gameID] == nil)
    }
}
