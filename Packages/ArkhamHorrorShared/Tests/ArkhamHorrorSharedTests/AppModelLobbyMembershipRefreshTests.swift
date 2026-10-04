@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — lobby membership refresh after seating")
struct AppModelLobbyMembershipRefreshTests {
    private func getGameEnvelope(playerID: PlayerID? = PlayerID(UUID())) -> GetGameEnvelope {
        GetGameEnvelope(
            playerID: playerID,
            multiplayerMode: .withFriends,
            game: BoardTestFixtures.snapshot(playerCount: 3),
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

    private func assertClaimButtonsHiddenAfterMembershipReload(
        gameID: GameID,
        seat: CardCode,
        model: AppModel,
        service: ScriptedGameLifecycleService
    ) async throws {
        await service.waitUntilGetGamePending(1)
        let detailTask = try #require(model.gameLobbyDetailTasks[gameID])
        await service.resumeOldestGetGame(with: .success(getGameEnvelope()))
        await detailTask.value

        let view = GameLobbyView(model: model, gameID: gameID)
        #expect(model.gameLobbyViewerHasSeats[gameID] == true)
        #expect(!view.showsClaimSeatButtons(for: gameSummary(id: gameID), openSeats: [seat]))
    }

    @Test("lobby claim success reloads viewer membership and hides claim buttons")
    func lobbyClaimReloadsMembership() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        await service.enqueueClaimSeatResult(.success(()))
        await service.enqueueListGamesResult(.success([.game(gameSummary(id: gameID))]))
        await service.setGetGameGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        model.gameLobbyViewerHasSeats[gameID] = false
        model.gameLobbyPlayerCounts[gameID] = 3
        model.gameOpenSeats[gameID] = [seat]
        let view = GameLobbyView(model: model, gameID: gameID)
        #expect(view.showsClaimSeatButtons(for: gameSummary(id: gameID), openSeats: [seat]))

        model.claimSeat(seat, in: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value
        try await assertClaimButtonsHiddenAfterMembershipReload(
            gameID: gameID,
            seat: seat,
            model: model,
            service: service
        )
        await model.gameListTask?.value

        let callOrder = await service.callOrder
        #expect(callOrder.filter { $0 == "claimSeat" }.count == 1)
        #expect(callOrder.filter { $0 == "getGame" }.count == 1)
    }

    @Test("lobby join success reloads viewer membership and hides claim buttons")
    func lobbyJoinReloadsMembership() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01002")
        await service.enqueueJoinGameResult(.success(.game(gameID)))
        await service.enqueueListGamesResult(.success([.game(gameSummary(id: gameID))]))
        await service.setGetGameGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        model.gameLobbyViewerHasSeats[gameID] = false
        model.gameLobbyPlayerCounts[gameID] = 3
        model.gameOpenSeats[gameID] = [seat]

        model.joinGame(gameID)
        await model.gameLifecycleActionTasks[gameID]?.value
        try await assertClaimButtonsHiddenAfterMembershipReload(
            gameID: gameID,
            seat: seat,
            model: model,
            service: service
        )
        await model.gameListTask?.value

        let callOrder = await service.callOrder
        #expect(callOrder.filter { $0 == "joinGame" }.count == 1)
        #expect(callOrder.filter { $0 == "getGame" }.count == 1)
    }

    @Test("claim-seat invite success reloads viewer membership and hides claim buttons")
    func claimSeatInviteReloadsMembership() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        await service.enqueuePeekLobbyResult(.success(.game(gameID, playerCount: 3)))
        await service.enqueueOpenSeatsResult(.success([seat]))
        await service.enqueueGetGameResult(.failure(GameLifecycleError.unexpectedStatus(404)))
        await service.enqueueClaimSeatResult(.success(()))
        await service.enqueueListGamesResult(.success([.game(gameSummary(id: gameID))]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let invite = try await model.loadClaimSeatInvite(gameID)
        await service.setGetGameGated(true)
        _ = try await model.claimSeatFromInvite(seat, using: invite)
        try await assertClaimButtonsHiddenAfterMembershipReload(
            gameID: gameID,
            seat: seat,
            model: model,
            service: service
        )

        let callOrder = await service.callOrder
        #expect(callOrder.filter { $0 == "claimSeat" }.count == 1)
        #expect(callOrder.filter { $0 == "getGame" }.count == 2)
    }

    @Test("join invite success reloads viewer membership and hides claim buttons")
    func joinInviteReloadsMembership() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01003")
        await service.enqueuePeekLobbyResult(.success(.game(gameID, playerCount: 3)))
        await service.enqueueJoinGameResult(.success(.game(gameID)))
        await service.enqueueListGamesResult(.success([.game(gameSummary(id: gameID))]))
        await service.setGetGameGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        model.gameLobbyViewerHasSeats[gameID] = false
        model.gameLobbyPlayerCounts[gameID] = 3

        _ = try await model.joinGameFromInvite(gameID)
        try await assertClaimButtonsHiddenAfterMembershipReload(
            gameID: gameID,
            seat: seat,
            model: model,
            service: service
        )

        let callOrder = await service.callOrder
        #expect(callOrder.filter { $0 == "joinGame" }.count == 1)
        #expect(callOrder.filter { $0 == "getGame" }.count == 1)
    }
}
