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

    private func gameSummary(id: GameID) -> GameSummary {
        GameSummary(
            id: id,
            scenario: nil,
            campaign: nil,
            gameState: .pending([]),
            name: "Sample",
            investigators: [],
            otherInvestigators: [],
            multiplayerVariant: .withFriends,
            hasOpenSeats: false
        )
    }

    @Test("joinGameFromInvite peeks, joins, refreshes, and waits through AppModel")
    func joinGameFromInvitePeeksJoinsAndRefreshes() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.success(.game(gameID, playerCount: 3)))
        await service.enqueueJoinGameResult(.success(.game(gameID)))
        await service.enqueueListGamesResult(.success([.game(gameSummary(id: gameID))]))
        await service.enqueueGetGameResult(.success(
            getGameEnvelope(gameID: gameID, playerCount: 3)
        ))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let joinedID = try await model.joinGameFromInvite(gameID)
        await model.gameLobbyDetailTasks[gameID]?.value

        #expect(joinedID == gameID)
        #expect(await service.callOrder == ["peekLobby", "joinGame", "listGames", "getGame"])
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
        await service.enqueueGetGameResult(.success(
            getGameEnvelope(gameID: gameID, playerCount: 2)
        ))
        await service.enqueueClaimSeatResult(.success(()))
        await service.enqueueListGamesResult(.success([.game(gameSummary(id: gameID))]))
        await service.enqueueGetGameResult(.success(
            getGameEnvelope(gameID: gameID, playerCount: 2)
        ))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let invite = try await model.loadClaimSeatInvite(gameID)
        let claimedID = try await model.claimSeatFromInvite(invite.seats[0], using: invite)
        await model.gameLobbyDetailTasks[gameID]?.value

        #expect(invite.seats == [seat])
        #expect(invite.viewerHasSeat)
        #expect(invite.playerCount == 2)
        #expect(claimedID == gameID)
        #expect(
            await service.callOrder == [
                "peekLobby", "openSeats", "getGame", "claimSeat", "listGames", "getGame",
            ]
        )
        #expect(await service.lastPeekLobbyGameID == gameID)
        #expect(await service.lastOpenSeatsGameID == gameID)
        #expect(await service.lastClaimSeatGameID == gameID)
        let expectedInvestigator = try InvestigatorCode("c01001")
        #expect(await service.lastClaimSeatRequest?.investigatorId == expectedInvestigator)
    }

    @Test("claim-seat invite lets a viewer without a seat claim an open seat")
    func claimSeatInviteClaimsSeatForUnseatedViewer() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        await service.enqueuePeekLobbyResult(.success(.game(gameID, playerCount: 2)))
        await service.enqueueOpenSeatsResult(.success([seat]))
        await service.enqueueGetGameResult(.failure(GameLifecycleError.unexpectedStatus(404)))
        await service.enqueueClaimSeatResult(.success(()))
        await service.enqueueListGamesResult(.success([.game(gameSummary(id: gameID))]))
        await service.enqueueGetGameResult(.success(
            getGameEnvelope(gameID: gameID, playerCount: 2)
        ))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let invite = try await model.loadClaimSeatInvite(gameID)
        let claimedID = try await model.claimSeatFromInvite(seat, using: invite)
        await model.gameLobbyDetailTasks[gameID]?.value

        #expect(invite.seats == [seat])
        #expect(invite.viewerHasSeat == false)
        #expect(invite.showsClaimButtons)
        #expect(claimedID == gameID)
        #expect(
            await service.callOrder == [
                "peekLobby", "openSeats", "getGame", "claimSeat", "listGames", "getGame",
            ]
        )
    }

    @Test("claim-seat invite reports viewer as unseated after full-game 404 without publishing")
    func claimSeatInviteReportsFullGame404WithoutPublishingSeatStatus() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        await service.enqueuePeekLobbyResult(.success(.game(gameID, playerCount: 2)))
        await service.enqueueOpenSeatsResult(.success([seat]))
        await service.enqueueGetGameResult(.failure(GameLifecycleError.unexpectedStatus(404)))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        model.gameLobbyViewerHasSeats[gameID] = true

        let invite = try await model.loadClaimSeatInvite(gameID)

        #expect(invite.viewerHasSeat == false)
        #expect(invite.showsClaimButtons)
        #expect(model.gameLobbyViewerHasSeats[gameID] == true)
        #expect(await service.callOrder == ["peekLobby", "openSeats", "getGame"])
    }

    @Test("claim-seat invite snapshot does not overwrite published lobby membership")
    func claimSeatInviteSnapshotDoesNotOverwritePublishedLobbyMembership() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        await service.enqueuePeekLobbyResult(.success(.game(gameID, playerCount: 4)))
        await service.enqueueOpenSeatsResult(.success([seat]))
        await service.enqueueGetGameResult(.success(
            getGameEnvelope(gameID: gameID, playerID: PlayerID(UUID()), playerCount: 4)
        ))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        model.gameLobbyViewerHasSeats[gameID] = false
        model.gameLobbyViewerSeatFailures[gameID] = .unexpectedStatus(500)

        let invite = try await model.loadClaimSeatInvite(gameID)

        #expect(invite.viewerHasSeat)
        #expect(invite.canContinue == false)
        #expect(model.gameLobbyViewerHasSeats[gameID] == false)
        #expect(model.gameLobbyViewerSeatFailures[gameID] == .unexpectedStatus(500))
        #expect(await service.callOrder == ["peekLobby", "openSeats", "getGame"])
    }

    @Test("claim-seat invite snapshot cannot republish stale lobby flags after reset")
    func claimSeatInviteRejectsSnapshotAfterReset() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        await service.enqueuePeekLobbyResult(.success(.game(gameID, playerCount: 3)))
        await service.enqueueOpenSeatsResult(.success([seat]))
        await service.setGetGameGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let loadTask = Task { try await model.loadClaimSeatInvite(gameID) }
        await service.waitUntilGetGamePending(1)
        model.generation += 1
        model.resetGameLifecycleState()
        await service.resumeOldestGetGame(with: .success(
            getGameEnvelope(gameID: gameID, playerCount: 3)
        ))

        await #expect(throws: CancellationError.self) {
            _ = try await loadTask.value
        }
        #expect(model.gameLobbyPlayerCounts[gameID] == nil)
        #expect(model.gameLobbyViewerHasSeats[gameID] == nil)
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
        let originalGeneration = model.generation
        model.generation += 1

        await #expect(throws: CancellationError.self) {
            try await model.claimSeatFromInvite(seat, using: invite)
        }
        #expect(model.generation == originalGeneration + 1)
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
}
