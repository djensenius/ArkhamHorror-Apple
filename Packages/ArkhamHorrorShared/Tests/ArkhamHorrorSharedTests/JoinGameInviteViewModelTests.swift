@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("JoinGameInviteViewModel")
struct JoinGameInviteViewModelTests {
    private let gameID = GameID(UUID(uuidString: "00000000-0000-0000-0000-000000000042")!)
    private let sessionToken = GameInviteSessionToken(
        profileID: ServerProfile.hosted.id,
        generation: 1,
        credentialEpoch: 0,
        globalEpoch: 0
    )

    private func inviteDetails(
        seats: OpenSeats,
        viewerHasSeat: Bool = false,
        playerCount: Int = 2
    ) -> ClaimSeatInviteViewState {
        ClaimSeatInviteViewState(
            gameID: gameID,
            seats: seats,
            playerCount: playerCount,
            viewerHasSeat: viewerHasSeat,
            sessionToken: sessionToken
        )
    }

    @Test("empty and invalid invite input report validation text")
    func invalidInviteText() async {
        let viewModel = JoinGameInviteViewModel()
        viewModel.inviteText = "   "

        let result = await viewModel.submit(
            joinInvite: { _ in Issue.record("join should not run"); return gameID },
            loadClaimSeatInvite: { _ in
                Issue.record("claim load should not run")
                return inviteDetails(seats: [])
            }
        )

        #expect(result == nil)
        #expect(viewModel.failureMessage == "Enter a game invite link or game ID.")
    }

    @Test("join links call the join flow and return the joined game id")
    func joinInviteSubmitsJoinFlow() async {
        let viewModel = JoinGameInviteViewModel()
        viewModel.inviteText = "https://arkhamhorror.app/games/\(gameID.rawValue.uuidString)/join"
        var joinedGameID: GameID?

        let result = await viewModel.submit(
            joinInvite: { id in
                joinedGameID = id
                return id
            },
            loadClaimSeatInvite: { _ in
                Issue.record("claim load should not run")
                return inviteDetails(seats: [])
            }
        )

        #expect(result == gameID)
        #expect(joinedGameID == gameID)
        #expect(viewModel.claimSeatInvite == nil)
        #expect(viewModel.failureMessage == nil)
    }

    @Test("join links keep the sheet open when joining or refreshing fails")
    func joinInviteKeepsSheetOpenOnLifecycleFailure() async {
        let viewModel = JoinGameInviteViewModel()
        viewModel.inviteText = "https://arkhamhorror.app/games/\(gameID.rawValue.uuidString)/join"

        let result = await viewModel.submit(
            joinInvite: { _ in throw GameLifecycleError.unexpectedStatus(500) },
            loadClaimSeatInvite: { _ in
                Issue.record("claim load should not run")
                return inviteDetails(seats: [])
            }
        )

        #expect(result == nil)
        #expect(viewModel.failureMessage == "This server responded unexpectedly. Try again.")
        #expect(viewModel.claimSeatInvite == nil)
    }

    @Test("claim-seat links load open seats without joining")
    func claimSeatInviteLoadsOpenSeats() async throws {
        let viewModel = JoinGameInviteViewModel()
        let seat = try CardCode("c01001")
        let claimSeatURL = "https://arkhamhorror.app/games/"
            + "\(gameID.rawValue.uuidString)/claim-seat"
        viewModel.inviteText = claimSeatURL
        var loadedGameID: GameID?
        let details = inviteDetails(seats: [seat], playerCount: 3)

        let result = await viewModel.submit(
            joinInvite: { _ in Issue.record("join should not run"); return gameID },
            loadClaimSeatInvite: { id in
                loadedGameID = id
                return details
            }
        )

        #expect(result == nil)
        #expect(loadedGameID == gameID)
        #expect(viewModel.claimSeatInvite == details)
        #expect(viewModel.failureMessage == nil)
    }

    @Test("claim-seat links hide claim buttons when server data says the viewer is seated")
    func claimSeatInviteRecordsAlreadySeatedViewer() async throws {
        let viewModel = JoinGameInviteViewModel()
        let seat = try CardCode("c01001")
        let claimSeatURL = "https://arkhamhorror.app/games/"
            + "\(gameID.rawValue.uuidString)/claim-seat"
        viewModel.inviteText = claimSeatURL
        let details = inviteDetails(seats: [seat], viewerHasSeat: true)

        _ = await viewModel.submit(
            joinInvite: { _ in Issue.record("join should not run"); return gameID },
            loadClaimSeatInvite: { _ in details }
        )

        #expect(viewModel.claimSeatInvite?.viewerHasSeat == true)
        #expect(viewModel.claimSeatInvite?.showsClaimButtons == false)
        #expect(viewModel.claimSeatInvite?.seats == [seat])
    }

    @Test("claiming a loaded seat returns the game id and preserves server errors verbatim")
    func claimLoadedSeat() async throws {
        let viewModel = JoinGameInviteViewModel()
        let seat = try CardCode("c01001")
        let claimSeatURL = "https://arkhamhorror.app/games/"
            + "\(gameID.rawValue.uuidString)/claim-seat"
        let details = inviteDetails(seats: [seat])
        viewModel.inviteText = claimSeatURL
        _ = await viewModel.submit(
            joinInvite: { _ in Issue.record("join should not run"); return gameID },
            loadClaimSeatInvite: { _ in details }
        )

        let claimed = await viewModel.claimSeat(
            seat,
            claimSeatInvite: { claimedSeat, invite in
                #expect(claimedSeat == seat)
                #expect(invite == details)
                return invite.gameID
            },
            reloadClaimSeatInvite: { _ in Issue.record("reload should not run"); return details }
        )
        #expect(claimed == gameID)

        let refreshedDetails = inviteDetails(seats: [])
        let failed = await viewModel.claimSeat(
            seat,
            claimSeatInvite: { _, _ in
                throw GameLifecycleError.operationFailed(
                    DeckOperationError(errorMsg: "Permission Denied. This seat is already taken")
                )
            },
            reloadClaimSeatInvite: { id in
                #expect(id == gameID)
                return refreshedDetails
            }
        )
        #expect(failed == nil)
        #expect(viewModel.failureMessage == "Permission Denied. This seat is already taken")
        #expect(viewModel.claimSeatInvite == refreshedDetails)
    }

    @Test("failed claim keeps the previous invite when refreshing open seats fails")
    func failedClaimKeepsPreviousInviteOnReloadFailure() async throws {
        let viewModel = JoinGameInviteViewModel()
        let seat = try CardCode("c01001")
        let details = inviteDetails(seats: [seat])
        viewModel.inviteText = "https://arkhamhorror.app/games/"
            + "\(gameID.rawValue.uuidString)/claim-seat"
        _ = await viewModel.submit(
            joinInvite: { _ in Issue.record("join should not run"); return gameID },
            loadClaimSeatInvite: { _ in details }
        )

        let failed = await viewModel.claimSeat(
            seat,
            claimSeatInvite: { _, _ in
                throw GameLifecycleError.operationFailed(
                    DeckOperationError(errorMsg: "Permission Denied. This seat is already taken")
                )
            },
            reloadClaimSeatInvite: { _ in throw GameLifecycleError.transportFailure("network") }
        )

        #expect(failed == nil)
        #expect(viewModel.failureMessage == "Permission Denied. This seat is already taken")
        #expect(viewModel.claimSeatInvite == details)
    }

    @Test("cancellation clears submitting state without showing an error")
    func cancellationClearsSubmittingState() async {
        let viewModel = JoinGameInviteViewModel()
        viewModel.inviteText = gameID.rawValue.uuidString

        let result = await viewModel.submit(
            joinInvite: { _ in throw CancellationError() },
            loadClaimSeatInvite: { _ in
                Issue.record("claim load should not run")
                return inviteDetails(seats: [])
            }
        )

        #expect(result == nil)
        #expect(viewModel.isSubmitting == false)
        #expect(viewModel.failureMessage == nil)
    }
}
