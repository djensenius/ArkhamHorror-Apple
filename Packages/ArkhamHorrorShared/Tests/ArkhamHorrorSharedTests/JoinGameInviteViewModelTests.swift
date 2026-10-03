@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("JoinGameInviteViewModel")
struct JoinGameInviteViewModelTests {
    private let gameID = GameID(UUID(uuidString: "00000000-0000-0000-0000-000000000042")!)

    @Test("empty and invalid invite input report validation text")
    func invalidInviteText() async {
        let viewModel = JoinGameInviteViewModel()
        viewModel.inviteText = "   "

        let result = await viewModel.submit(
            joinInvite: { _ in Issue.record("join should not run"); return gameID },
            loadClaimSeatInvite: { _ in Issue.record("claim load should not run"); return [] }
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
            loadClaimSeatInvite: { _ in Issue.record("claim load should not run"); return [] }
        )

        #expect(result == gameID)
        #expect(joinedGameID == gameID)
        #expect(viewModel.claimSeatInvite == nil)
        #expect(viewModel.failureMessage == nil)
    }

    @Test("claim-seat links load open seats without joining")
    func claimSeatInviteLoadsOpenSeats() async throws {
        let viewModel = JoinGameInviteViewModel()
        let seat = try CardCode("c01001")
        let claimSeatURL = "https://arkhamhorror.app/games/"
            + "\(gameID.rawValue.uuidString)/claim-seat"
        viewModel.inviteText = claimSeatURL
        var loadedGameID: GameID?

        let result = await viewModel.submit(
            joinInvite: { _ in Issue.record("join should not run"); return gameID },
            loadClaimSeatInvite: { id in
                loadedGameID = id
                return [seat]
            }
        )

        #expect(result == nil)
        #expect(loadedGameID == gameID)
        #expect(
            viewModel.claimSeatInvite == ClaimSeatInviteViewState(gameID: gameID, seats: [seat])
        )
        #expect(viewModel.failureMessage == nil)
    }

    @Test("claiming a loaded seat returns the game id and preserves server errors verbatim")
    func claimLoadedSeat() async throws {
        let viewModel = JoinGameInviteViewModel()
        let seat = try CardCode("c01001")
        let claimSeatURL = "https://arkhamhorror.app/games/"
            + "\(gameID.rawValue.uuidString)/claim-seat"
        viewModel.inviteText = claimSeatURL
        _ = await viewModel.submit(
            joinInvite: { _ in Issue.record("join should not run"); return gameID },
            loadClaimSeatInvite: { _ in [seat] }
        )

        let claimed = await viewModel.claimSeat(seat) { claimedSeat, id in
            #expect(claimedSeat == seat)
            #expect(id == gameID)
            return id
        }
        #expect(claimed == gameID)

        let failed = await viewModel.claimSeat(seat) { _, _ in
            throw GameLifecycleError.operationFailed(
                DeckOperationError(errorMsg: "This seat is already taken")
            )
        }
        #expect(failed == nil)
        #expect(viewModel.failureMessage == "This seat is already taken")
    }

    @Test("cancellation clears submitting state without showing an error")
    func cancellationClearsSubmittingState() async {
        let viewModel = JoinGameInviteViewModel()
        viewModel.inviteText = gameID.rawValue.uuidString

        let result = await viewModel.submit(
            joinInvite: { _ in throw CancellationError() },
            loadClaimSeatInvite: { _ in Issue.record("claim load should not run"); return [] }
        )

        #expect(result == nil)
        #expect(viewModel.isSubmitting == false)
        #expect(viewModel.failureMessage == nil)
    }
}
