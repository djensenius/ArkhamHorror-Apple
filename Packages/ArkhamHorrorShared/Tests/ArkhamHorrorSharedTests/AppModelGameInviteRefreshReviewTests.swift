@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — game invite refresh review fixes")
struct AppModelGameInviteRefreshReviewTests {
    private let refreshFailureMessage = "Joined, but the game list could not be refreshed. "
        + "Try again."

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

    private func inviteDetails(
        gameID: GameID,
        seat: CardCode,
        model: AppModel
    ) -> ClaimSeatInviteDetails {
        ClaimSeatInviteDetails(
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
    }

    @Test("join invite hands off when the refreshed list contains the joined game")
    func joinInviteHandoffsWhenRefreshContainsGame() async {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.success(.game(gameID)))
        await service.enqueueJoinGameResult(.success(.game(gameID)))
        await service.enqueueListGamesResult(.success([.game(gameSummary(id: gameID))]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        let viewModel = JoinGameInviteViewModel()
        viewModel.inviteText = "https://arkhamhorror.app/games/\(gameID.rawValue.uuidString)/join"

        let joinedID = await viewModel.submit(
            joinInvite: { id in try await model.joinGameFromInvite(id) },
            loadClaimSeatInvite: { _ in
                Issue.record("claim load should not run")
                return ClaimSeatInviteDetails(
                    gameID: gameID,
                    seats: [],
                    playerCount: 2,
                    viewerHasSeat: false,
                    sessionToken: GameInviteSessionToken(
                        profileID: ServerProfile.hosted.id,
                        generation: 0,
                        credentialEpoch: 0,
                        globalEpoch: 0
                    )
                )
            }
        )

        #expect(joinedID == gameID)
        #expect(viewModel.failureMessage == nil)
        #expect(await service.callOrder == ["peekLobby", "joinGame", "listGames"])
    }

    @Test("join invite stays open when the refreshed list omits the joined game")
    func joinInviteReportsMissingGameAfterRefresh() async {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let otherGameID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.success(.game(gameID)))
        await service.enqueueJoinGameResult(.success(.game(gameID)))
        await service.enqueueListGamesResult(.success([
            .failed(FailedGameEntry(error: "Could not load this game.")),
            .game(gameSummary(id: otherGameID)),
        ]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        let viewModel = JoinGameInviteViewModel()
        viewModel.inviteText = "https://arkhamhorror.app/games/\(gameID.rawValue.uuidString)/join"

        let joinedID = await viewModel.submit(
            joinInvite: { id in try await model.joinGameFromInvite(id) },
            loadClaimSeatInvite: { _ in
                Issue.record("claim load should not run")
                return ClaimSeatInviteDetails(
                    gameID: gameID,
                    seats: [],
                    playerCount: 2,
                    viewerHasSeat: false,
                    sessionToken: GameInviteSessionToken(
                        profileID: ServerProfile.hosted.id,
                        generation: 0,
                        credentialEpoch: 0,
                        globalEpoch: 0
                    )
                )
            }
        )

        #expect(joinedID == nil)
        #expect(viewModel.failureMessage == refreshFailureMessage)
        #expect(viewModel.isSubmitting == false)
        #expect(await service.callOrder == ["peekLobby", "joinGame", "listGames"])
    }

    @Test("claim-seat invite stays open when the post-claim refresh omits the game")
    func claimSeatInviteReportsMissingGameAfterRefresh() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        await service.enqueueClaimSeatResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        let details = inviteDetails(gameID: gameID, seat: seat, model: model)
        let reloadedDetails = ClaimSeatInviteDetails(
            gameID: gameID,
            seats: [],
            playerCount: details.playerCount,
            viewerHasSeat: true,
            sessionToken: details.sessionToken
        )
        let viewModel = JoinGameInviteViewModel()
        viewModel.inviteText = "https://arkhamhorror.app/games/"
            + "\(gameID.rawValue.uuidString)/claim-seat"
        _ = await viewModel.submit(
            joinInvite: { _ in Issue.record("join should not run"); return gameID },
            loadClaimSeatInvite: { _ in details }
        )

        let claimedID = await viewModel.claimSeat(
            seat,
            claimSeatInvite: { seat, invite in
                try await model.claimSeatFromInvite(seat, using: invite)
            },
            reloadClaimSeatInvite: { _ in
                reloadedDetails
            }
        )

        #expect(claimedID == nil)
        #expect(viewModel.failureMessage == refreshFailureMessage)
        #expect(viewModel.claimSeatInvite == reloadedDetails)
        #expect(viewModel.claimSeatInvite?.canContinue == true)
        #expect(await service.callOrder == ["claimSeat", "listGames"])
    }
}
