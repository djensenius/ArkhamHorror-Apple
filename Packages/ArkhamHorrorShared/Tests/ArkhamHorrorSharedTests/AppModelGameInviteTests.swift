@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — game invites")
struct AppModelGameInviteTests {
    @Test("joinGameFromInvite peeks, joins, refreshes, and waits through AppModel")
    func joinGameFromInvitePeeksJoinsAndRefreshes() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.success(.game(gameID)))
        await service.enqueueJoinGameResult(.success(.game(gameID)))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let joinedID = try await model.joinGameFromInvite(gameID)

        #expect(joinedID == gameID)
        #expect(await service.callOrder == ["peekLobby", "joinGame", "listGames"])
        #expect(await service.lastPeekLobbyGameID == gameID)
        #expect(await service.lastJoinGameID == gameID)
        #expect(await service.lastToken == "session-token")
    }

    @Test("claim-seat invite peeks, loads open seats, claims, and refreshes without PUT join")
    func claimSeatInviteUsesClaimSeatFlow() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        await service.enqueuePeekLobbyResult(.success(.game(gameID)))
        await service.enqueueOpenSeatsResult(.success([seat]))
        await service.enqueueClaimSeatResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let seats = try await model.loadClaimSeatInvite(gameID)
        let claimedID = try await model.claimSeatFromInvite(seats[0], in: gameID)

        #expect(seats == [seat])
        #expect(claimedID == gameID)
        #expect(await service.callOrder == ["peekLobby", "openSeats", "claimSeat", "listGames"])
        #expect(await service.lastPeekLobbyGameID == gameID)
        #expect(await service.lastOpenSeatsGameID == gameID)
        #expect(await service.lastClaimSeatGameID == gameID)
        let expectedInvestigator = try InvestigatorCode("c01001")
        #expect(await service.lastClaimSeatRequest?.investigatorId == expectedInvestigator)
    }

    @Test("joinGameFromInvite surfaces server-authored lobby errors verbatim")
    func joinGameFromInviteSurfacesServerMessage() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let error = DeckOperationError(errorMsg: "This seat is already taken")
        await service.enqueuePeekLobbyResult(.success(.game(gameID)))
        await service.enqueueJoinGameResult(.failure(GameLifecycleError.operationFailed(error)))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        do {
            _ = try await model.joinGameFromInvite(gameID)
            Issue.record("Expected the server-authored error to be thrown")
        } catch let thrown as GameLifecycleError {
            #expect(thrown == .operationFailed(error))
            #expect(thrown.message == "This seat is already taken")
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
