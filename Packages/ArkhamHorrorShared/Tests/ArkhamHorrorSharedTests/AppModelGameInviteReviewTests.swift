@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — game invite review fixes")
struct AppModelGameInviteReviewTests {
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

    @Test("claim-seat Continue refreshes without issuing PUT join")
    func claimSeatContinueRefreshesWithoutJoining() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.success(.game(gameID, playerCount: 2)))
        await service.enqueueOpenSeatsResult(.success([]))
        await service.enqueueGetGameResult(.success(
            getGameEnvelope(gameID: gameID, playerCount: 2)
        ))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let invite = try await model.loadClaimSeatInvite(gameID)
        let continuedID = try await model.continueClaimSeatInvite(using: invite)

        #expect(invite.canContinue)
        #expect(continuedID == gameID)
        #expect(await service.callOrder == ["peekLobby", "openSeats", "getGame", "listGames"])
        #expect(await service.lastJoinGameID == nil)
    }

    @Test("claim-seat Continue keeps the invite open when refresh fails")
    func claimSeatContinueSurfacesRefreshFailure() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.success(.game(gameID, playerCount: 2)))
        await service.enqueueOpenSeatsResult(.success([]))
        await service.enqueueGetGameResult(.success(
            getGameEnvelope(gameID: gameID, playerCount: 2)
        ))
        await service.enqueueListGamesResult(.failure(GameLifecycleError.unexpectedStatus(500)))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let invite = try await model.loadClaimSeatInvite(gameID)
        await #expect(throws: GameLifecycleError.unexpectedStatus(500)) {
            try await model.continueClaimSeatInvite(using: invite)
        }

        #expect(invite.canContinue)
        #expect(await service.callOrder == ["peekLobby", "openSeats", "getGame", "listGames"])
        #expect(await service.lastJoinGameID == nil)
    }

    @Test("claim-seat invite propagates non-404 full-game snapshot failures")
    func claimSeatInvitePropagatesNon404SnapshotFailures() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        await service.enqueuePeekLobbyResult(.success(.game(gameID, playerCount: 2)))
        await service.enqueueOpenSeatsResult(.success([seat]))
        await service.enqueueGetGameResult(.failure(GameLifecycleError.unexpectedStatus(403)))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        await #expect(throws: GameLifecycleError.unexpectedStatus(403)) {
            _ = try await model.loadClaimSeatInvite(gameID)
        }
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

    @Test("claim-seat invite revalidates before propagating a claim failure")
    func claimSeatInviteRejectsSessionChangeBeforeClaimFailure() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        await service.setClaimSeatGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        let invite = ClaimSeatInviteDetails(
            gameID: gameID,
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
        await service.waitUntilClaimSeatPending(1)
        model.generation += 1
        await service.resumeOldestClaimSeat(with: .failure(
            GameLifecycleError.unexpectedStatus(409)
        ))

        await #expect(throws: CancellationError.self) {
            _ = try await claimTask.value
        }
        #expect(await service.callOrder == ["claimSeat"])
    }

    @Test("claim-seat invite revalidates after handling a session-expired claim failure")
    func claimSeatInviteRejectsSessionChangeAfterSessionExpiredHandler() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        await service.enqueueClaimSeatResult(.failure(GameLifecycleError.sessionExpired))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        let invite = ClaimSeatInviteDetails(
            gameID: gameID,
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

        await #expect(throws: CancellationError.self) {
            try await model.claimSeatFromInvite(seat, using: invite)
        }
        #expect(await service.callOrder == ["claimSeat"])
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }

    @Test("joinGameFromInvite surfaces a failed post-join refresh")
    func joinGameFromInviteSurfacesRefreshFailure() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.success(.game(gameID)))
        await service.enqueueJoinGameResult(.success(.game(gameID)))
        await service.enqueueListGamesResult(.failure(GameLifecycleError.unexpectedStatus(500)))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        await #expect(throws: GameLifecycleError.unexpectedStatus(500)) {
            try await model.joinGameFromInvite(gameID)
        }
        #expect(await service.callOrder == ["peekLobby", "joinGame", "listGames"])
        #expect(model.gameListState == .failed(.unexpectedStatus(500), previous: nil))
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
