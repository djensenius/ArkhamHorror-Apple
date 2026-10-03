@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — game invites")
struct AppModelGameInviteTests {
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

    @Test("joinGameFromInvite peeks, joins, refreshes, and waits through AppModel")
    func joinGameFromInvitePeeksJoinsAndRefreshes() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.success(.game(gameID, playerCount: 3)))
        await service.enqueueJoinGameResult(.success(.game(gameID)))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let joinedID = try await model.joinGameFromInvite(gameID)

        #expect(joinedID == gameID)
        #expect(await service.callOrder == ["peekLobby", "joinGame", "listGames"])
        #expect(await service.lastPeekLobbyGameID == gameID)
        #expect(await service.lastJoinGameID == gameID)
        #expect(await service.lastToken == "session-token")
        #expect(model.gameLobbyPlayerCounts[gameID] == 3)
    }

    @Test("claim-seat invite peeks, loads open seats, claims, and refreshes without PUT join")
    func claimSeatInviteUsesClaimSeatFlow() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        await service.enqueuePeekLobbyResult(.success(.game(gameID, playerCount: 2)))
        await service.enqueueOpenSeatsResult(.success([seat]))
        await service.enqueueGetGameResult(.success(getGameEnvelope(gameID: gameID, playerCount: 2)))
        await service.enqueueClaimSeatResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let invite = try await model.loadClaimSeatInvite(gameID)
        let claimedID = try await model.claimSeatFromInvite(invite.seats[0], using: invite)

        #expect(invite.seats == [seat])
        #expect(invite.viewerHasSeat)
        #expect(invite.playerCount == 2)
        #expect(claimedID == gameID)
        #expect(await service.callOrder == ["peekLobby", "openSeats", "getGame", "claimSeat", "listGames"])
        #expect(await service.lastPeekLobbyGameID == gameID)
        #expect(await service.lastOpenSeatsGameID == gameID)
        #expect(await service.lastClaimSeatGameID == gameID)
        let expectedInvestigator = try InvestigatorCode("c01001")
        #expect(await service.lastClaimSeatRequest?.investigatorId == expectedInvestigator)
    }

    @Test("claim-seat invite cancellation protects a seat loaded by an old session")
    func claimSeatInviteRejectsSessionChangeAfterLoad() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        await service.enqueuePeekLobbyResult(.success(.game(gameID)))
        await service.enqueueOpenSeatsResult(.success([seat]))
        await service.enqueueGetGameResult(.success(getGameEnvelope(gameID: gameID)))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let invite = try await model.loadClaimSeatInvite(gameID)
        model.signOut()
        await model.flowTask?.value

        await #expect(throws: CancellationError.self) {
            try await model.claimSeatFromInvite(seat, using: invite)
        }
        #expect(await service.callOrder == ["peekLobby", "openSeats", "getGame"])
    }

    @Test("joinGameFromInvite surfaces server-authored lobby errors verbatim")
    func joinGameFromInviteSurfacesServerMessage() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let error = DeckOperationError(
            errorMsg: "Permission Denied. You already occupy a seat in another group in this event"
        )
        await service.enqueuePeekLobbyResult(.success(.game(gameID)))
        await service.enqueueJoinGameResult(.failure(GameLifecycleError.operationFailed(error)))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        do {
            _ = try await model.joinGameFromInvite(gameID)
            Issue.record("Expected the server-authored error to be thrown")
        } catch let thrown as GameLifecycleError {
            #expect(thrown == .operationFailed(error))
            #expect(thrown.message == error.errorMsg)
        }
        #expect(await service.callOrder == ["peekLobby", "joinGame"])
    }

    @Test("joinGameFromInvite rejects a preview for a different game")
    func joinGameFromInviteRejectsMismatchedPreview() async throws {
        let service = ScriptedGameLifecycleService()
        let requestedID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.success(.game(GameID(UUID()))))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        await #expect(throws: GameLifecycleError.malformedPayload) {
            try await model.joinGameFromInvite(requestedID)
        }
        #expect(await service.callOrder == ["peekLobby"])
    }
}
