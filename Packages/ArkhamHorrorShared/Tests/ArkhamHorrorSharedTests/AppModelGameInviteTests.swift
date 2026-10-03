@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — game invites")
struct AppModelGameInviteTests {
    @Test("joinGameFromInvite peeks, joins, and refreshes through AppModel")
    func joinGameFromInvitePeeksJoinsAndRefreshes() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.success(.game(gameID)))
        await service.enqueueJoinGameResult(.success(.game(gameID)))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let joinedID = try await model.joinGameFromInvite(gameID)
        await model.gameListTask?.value

        #expect(joinedID == gameID)
        #expect(await service.callOrder == ["peekLobby", "joinGame", "listGames"])
        #expect(await service.lastPeekLobbyGameID == gameID)
        #expect(await service.lastJoinGameID == gameID)
        #expect(await service.lastToken == "session-token")
    }

    @Test("joinGameFromInvite surfaces server-authored lobby errors verbatim")
    func joinGameFromInviteSurfacesServerMessage() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let error = DeckOperationError(errorMsg: "This game is full")
        await service.enqueuePeekLobbyResult(.success(.game(gameID)))
        await service.enqueueJoinGameResult(.failure(GameLifecycleError.operationFailed(error)))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        do {
            _ = try await model.joinGameFromInvite(gameID)
            Issue.record("Expected the server-authored error to be thrown")
        } catch let thrown as GameLifecycleError {
            #expect(thrown == .operationFailed(error))
            #expect(thrown.message == "This game is full")
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
