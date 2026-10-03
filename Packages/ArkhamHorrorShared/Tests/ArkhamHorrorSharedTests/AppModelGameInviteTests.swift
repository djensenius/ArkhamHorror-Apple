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
        await service.enqueueGetGameResult(.success(
            getGameEnvelope(gameID: gameID, playerCount: 2)
        ))
        await service.enqueueClaimSeatResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let invite = try await model.loadClaimSeatInvite(gameID)
        let claimedID = try await model.claimSeatFromInvite(invite.seats[0], using: invite)

        #expect(invite.seats == [seat])
        #expect(invite.viewerHasSeat)
        #expect(invite.playerCount == 2)
        #expect(claimedID == gameID)
        #expect(
            await service.callOrder == [
                "peekLobby", "openSeats", "getGame", "claimSeat", "listGames",
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
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let invite = try await model.loadClaimSeatInvite(gameID)
        let claimedID = try await model.claimSeatFromInvite(seat, using: invite)

        #expect(invite.seats == [seat])
        #expect(invite.viewerHasSeat == false)
        #expect(invite.showsClaimButtons)
        #expect(claimedID == gameID)
        #expect(
            await service.callOrder == [
                "peekLobby", "openSeats", "getGame", "claimSeat", "listGames",
            ]
        )
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

    @Test("claim-seat invite revalidates the captured session after reading the token")
    func claimSeatInviteRejectsSessionChangeAfterTokenRead() async throws {
        let service = ScriptedGameLifecycleService()
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "session-token"])
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: service
        )
        await model.flowTask?.value
        await tokenStore.setTokenReadGated(true)
        let seat = try CardCode("c01001")
        let invite = ClaimSeatInviteDetails(
            gameID: GameID(UUID()),
            seats: [seat],
            playerCount: 2,
            viewerHasSeat: false,
            sessionToken: GameInviteSessionToken(
                profileID: ServerProfile.hosted.id,
                generation: model.generation,
                credentialEpoch: model.currentCredentialEpoch(for: ServerProfile.hosted.id),
                globalEpoch: model.currentGlobalCredentialEpoch()
            )
        )

        let claimTask = Task { try await model.claimSeatFromInvite(seat, using: invite) }
        await tokenStore.waitUntilTokenReadPending(1)
        model.generation += 1
        await tokenStore.resumeOldestTokenRead(with: .success("session-token"))

        await #expect(throws: CancellationError.self) {
            _ = try await claimTask.value
        }
        #expect(await service.callOrder == [])
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

    @Test("joinGameFromInvite rejects a PUT join response for a different game")
    func joinGameFromInviteRejectsMismatchedJoinResponse() async throws {
        let service = ScriptedGameLifecycleService()
        let requestedID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.success(.game(requestedID)))
        await service.enqueueJoinGameResult(.success(.game(GameID(UUID()))))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        await #expect(throws: GameLifecycleError.malformedPayload) {
            try await model.joinGameFromInvite(requestedID)
        }
        #expect(await service.callOrder == ["peekLobby", "joinGame"])
    }
}
