@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — game invite superseded refresh review fixes")
struct AppModelGameInviteSupersededRefreshTests {
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

    private func claimSeatInviteDetails(
        gameID: GameID,
        seats: OpenSeats,
        viewerHasSeat: Bool,
        model: AppModel
    ) -> ClaimSeatInviteDetails {
        ClaimSeatInviteDetails(
            gameID: gameID,
            seats: seats,
            playerCount: 2,
            viewerHasSeat: viewerHasSeat,
            sessionToken: GameInviteSessionToken(
                profileID: ServerProfile.hosted.id,
                generation: model.generation,
                credentialEpoch: model.currentCredentialEpoch(for: ServerProfile.hosted.id),
                globalEpoch: model.currentGlobalCredentialEpoch()
            )
        )
    }

    @Test("claim-seat invite reports an error when its refresh is superseded")
    func claimSeatInviteReportsSupersededRefreshFailure() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        let targetGames: GameList = [.game(gameSummary(id: gameID))]
        await service.enqueueClaimSeatResult(.success(()))
        await service.setListGamesGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        let invite = claimSeatInviteDetails(
            gameID: gameID,
            seats: [seat],
            viewerHasSeat: false,
            model: model
        )

        let claimTask = Task { try await model.claimSeatFromInvite(seat, using: invite) }
        await service.waitUntilListGamesPending(1)
        model.refreshGames()
        await service.waitUntilListGamesPending(2)
        await service.resumeNewestListGames(with: .success(targetGames))
        await model.gameListTask?.value
        await service.resumeOldestListGames(with: .success(targetGames))

        await #expect(throws: GameLifecycleError.inviteRefreshFailed) {
            try await claimTask.value
        }
        #expect(await service.callOrder == ["claimSeat", "listGames", "listGames"])
    }

    @Test("claim-seat Continue reports an error when its refresh is superseded")
    func claimSeatContinueReportsSupersededRefreshFailure() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let targetGames: GameList = [.game(gameSummary(id: gameID))]
        await service.setListGamesGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        let invite = claimSeatInviteDetails(
            gameID: gameID,
            seats: [],
            viewerHasSeat: true,
            model: model
        )

        let continueTask = Task { try await model.continueClaimSeatInvite(using: invite) }
        await service.waitUntilListGamesPending(1)
        model.refreshGames()
        await service.waitUntilListGamesPending(2)
        await service.resumeNewestListGames(with: .success(targetGames))
        await model.gameListTask?.value
        await service.resumeOldestListGames(with: .success(targetGames))

        await #expect(throws: GameLifecycleError.inviteRefreshFailed) {
            try await continueTask.value
        }
        #expect(await service.callOrder == ["listGames", "listGames"])
    }

    @Test("cancelled invite refresh is not accepted from the restored previous list")
    func cancelledInviteRefreshDoesNotSucceedFromRestoredList() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        let targetGames: GameList = [.game(gameSummary(id: gameID))]
        await service.enqueueClaimSeatResult(.success(()))
        await service.enqueueListGamesResult(.failure(CancellationError()))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        model.gameListState = .loaded(targetGames)
        let invite = claimSeatInviteDetails(
            gameID: gameID,
            seats: [seat],
            viewerHasSeat: false,
            model: model
        )

        await #expect(throws: GameLifecycleError.inviteRefreshFailed) {
            try await model.claimSeatFromInvite(seat, using: invite)
        }

        #expect(model.gameListState == .loaded(targetGames))
        #expect(await service.callOrder == ["claimSeat", "listGames"])
    }
}
