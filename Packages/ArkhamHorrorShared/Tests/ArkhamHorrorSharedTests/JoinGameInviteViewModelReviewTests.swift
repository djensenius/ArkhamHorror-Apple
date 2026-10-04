@testable import ArkhamHorrorShared
import Foundation
import Testing

private actor ClaimSeatOperationGate {
    private var continuation: CheckedContinuation<GameID, Never>?
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilPending() async {
        if continuation != nil {
            return
        }
        await withCheckedContinuation {
            pendingWaiters.append($0)
        }
    }

    func run() async -> GameID {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            pendingWaiters.forEach { $0.resume() }
            pendingWaiters.removeAll()
        }
    }

    func resume(with gameID: GameID) {
        continuation?.resume(returning: gameID)
        continuation = nil
    }
}

private actor ClaimSeatInviteLoadGate {
    private var continuation: CheckedContinuation<ClaimSeatInviteViewState, Never>?
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilPending() async {
        if continuation != nil {
            return
        }
        await withCheckedContinuation {
            pendingWaiters.append($0)
        }
    }

    func run() async -> ClaimSeatInviteViewState {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            pendingWaiters.forEach { $0.resume() }
            pendingWaiters.removeAll()
        }
    }

    func resume(with invite: ClaimSeatInviteViewState) {
        continuation?.resume(returning: invite)
        continuation = nil
    }
}

@MainActor
@Suite("JoinGameInviteViewModel review fixes")
struct JoinGameInviteViewModelReviewTests {
    private let gameID = GameID(UUID(uuidString: "00000000-0000-0000-0000-000000000042")!)
    private let sessionToken = GameInviteSessionToken(
        profileID: ServerProfile.hosted.id,
        generation: 1,
        credentialEpoch: 0,
        globalEpoch: 0
    )

    private func inviteDetails(
        gameID: GameID? = nil,
        seats: OpenSeats,
        viewerHasSeat: Bool = false,
        playerCount: Int = 2
    ) -> ClaimSeatInviteViewState {
        ClaimSeatInviteViewState(
            gameID: gameID ?? self.gameID,
            seats: seats,
            playerCount: playerCount,
            viewerHasSeat: viewerHasSeat,
            sessionToken: sessionToken
        )
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

    @Test("Continue refreshes a seated invite before returning its game id")
    func continueRefreshesLoadedInviteBeforeJoining() async {
        let viewModel = JoinGameInviteViewModel()
        let details = inviteDetails(seats: [], viewerHasSeat: true)
        viewModel.inviteText = "https://arkhamhorror.app/games/"
            + "\(gameID.rawValue.uuidString)/claim-seat"
        _ = await viewModel.submit(
            joinInvite: { _ in Issue.record("join should not run"); return gameID },
            loadClaimSeatInvite: { _ in details }
        )
        var refreshedInvite: ClaimSeatInviteViewState?

        let continued = await viewModel.continueFromClaimSeatInvite { invite in
            refreshedInvite = invite
            return invite.gameID
        }

        #expect(continued == gameID)
        #expect(refreshedInvite == details)
        #expect(viewModel.claimSeatInvite == details)
        #expect(viewModel.failureMessage == nil)
    }

    @Test("Continue keeps the loaded invite when refresh fails")
    func continueKeepsLoadedInviteOnRefreshFailure() async {
        let viewModel = JoinGameInviteViewModel()
        let details = inviteDetails(seats: [], viewerHasSeat: true)
        viewModel.inviteText = "https://arkhamhorror.app/games/"
            + "\(gameID.rawValue.uuidString)/claim-seat"
        _ = await viewModel.submit(
            joinInvite: { _ in Issue.record("join should not run"); return gameID },
            loadClaimSeatInvite: { _ in details }
        )

        let continued = await viewModel.continueFromClaimSeatInvite { _ in
            throw GameLifecycleError.unexpectedStatus(500)
        }

        #expect(continued == nil)
        #expect(viewModel.claimSeatInvite == details)
        #expect(viewModel.failureMessage == "This server responded unexpectedly. Try again.")
    }

    @Test("changing the invite link clears the loaded claim-seat invite")
    func changingInviteLinkClearsLoadedClaimSeatInvite() async throws {
        let viewModel = JoinGameInviteViewModel()
        let firstSeat = try CardCode("c01001")
        let firstDetails = inviteDetails(seats: [firstSeat])
        let firstURL = "https://arkhamhorror.app/games/"
            + "\(gameID.rawValue.uuidString)/claim-seat"
        let secondGameUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000043"))
        let secondGameID = GameID(secondGameUUID)
        let secondURL = "https://arkhamhorror.app/games/"
            + "\(secondGameID.rawValue.uuidString)/claim-seat"
        viewModel.inviteText = firstURL
        _ = await viewModel.submit(
            joinInvite: { _ in Issue.record("join should not run"); return gameID },
            loadClaimSeatInvite: { _ in firstDetails }
        )
        #expect(viewModel.claimSeatInvite == firstDetails)

        viewModel.inviteText = secondURL

        #expect(viewModel.claimSeatInvite == nil)
        var actionCalled = false
        let claimed = await viewModel.claimSeat(
            firstSeat,
            claimSeatInvite: { _, _ in actionCalled = true; return gameID },
            reloadClaimSeatInvite: { _ in
                Issue.record("reload should not run")
                return firstDetails
            }
        )
        let continued = await viewModel.continueFromClaimSeatInvite { _ in
            actionCalled = true
            return gameID
        }
        #expect(claimed == nil)
        #expect(continued == nil)
        #expect(actionCalled == false)
    }

    @Test("late claim-seat loads are ignored after the invite link changes")
    func lateClaimSeatLoadDoesNotRestoreOldInvite() async throws {
        let viewModel = JoinGameInviteViewModel()
        let firstSeat = try CardCode("c01001")
        let firstDetails = inviteDetails(seats: [firstSeat])
        let firstURL = "https://arkhamhorror.app/games/"
            + "\(gameID.rawValue.uuidString)/claim-seat"
        let secondGameUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000043"))
        let secondGameID = GameID(secondGameUUID)
        let secondURL = "https://arkhamhorror.app/games/"
            + "\(secondGameID.rawValue.uuidString)/claim-seat"
        let gate = ClaimSeatInviteLoadGate()
        viewModel.inviteText = firstURL

        let loadTask = Task {
            await viewModel.submit(
                joinInvite: { _ in Issue.record("join should not run"); return gameID },
                loadClaimSeatInvite: { _ in await gate.run() }
            )
        }
        await gate.waitUntilPending()
        viewModel.inviteText = secondURL

        await gate.resume(with: firstDetails)

        #expect(await loadTask.value == nil)
        #expect(viewModel.claimSeatInvite == nil)
    }

    @Test("late claim-failure reloads are ignored after the invite link changes")
    func lateClaimFailureReloadDoesNotRestoreOldInvite() async throws {
        let viewModel = JoinGameInviteViewModel()
        let firstSeat = try CardCode("c01001")
        let firstDetails = inviteDetails(seats: [firstSeat])
        let refreshedDetails = inviteDetails(seats: [])
        let firstURL = "https://arkhamhorror.app/games/"
            + "\(gameID.rawValue.uuidString)/claim-seat"
        let secondGameUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000043"))
        let secondGameID = GameID(secondGameUUID)
        let secondURL = "https://arkhamhorror.app/games/"
            + "\(secondGameID.rawValue.uuidString)/claim-seat"
        let gate = ClaimSeatInviteLoadGate()
        let claimFailure = DeckOperationError(
            errorMsg: "Permission Denied. This seat is already taken"
        )
        viewModel.inviteText = firstURL
        _ = await viewModel.submit(
            joinInvite: { _ in Issue.record("join should not run"); return gameID },
            loadClaimSeatInvite: { _ in firstDetails }
        )

        let claimTask = Task {
            await viewModel.claimSeat(
                firstSeat,
                claimSeatInvite: { _, _ in
                    throw GameLifecycleError.operationFailed(claimFailure)
                },
                reloadClaimSeatInvite: { _ in await gate.run() }
            )
        }
        await gate.waitUntilPending()
        viewModel.inviteText = secondURL

        await gate.resume(with: refreshedDetails)

        #expect(await claimTask.value == nil)
        #expect(viewModel.claimSeatInvite == nil)
    }

    @Test("submitting is disabled while a seat claim is in flight")
    func submitIsDisabledWhileClaimingSeat() async throws {
        let viewModel = JoinGameInviteViewModel()
        let seat = try CardCode("c01001")
        let details = inviteDetails(seats: [seat])
        viewModel.inviteText = "https://arkhamhorror.app/games/"
            + "\(gameID.rawValue.uuidString)/claim-seat"
        _ = await viewModel.submit(
            joinInvite: { _ in Issue.record("join should not run"); return gameID },
            loadClaimSeatInvite: { _ in details }
        )
        let gate = ClaimSeatOperationGate()

        let claimTask = Task {
            await viewModel.claimSeat(
                seat,
                claimSeatInvite: { _, _ in await gate.run() },
                reloadClaimSeatInvite: { _ in
                    Issue.record("reload should not run")
                    return details
                }
            )
        }
        await gate.waitUntilPending()
        viewModel.inviteText = "https://arkhamhorror.app/games/"
            + "\(gameID.rawValue.uuidString)/join"

        #expect(viewModel.canSubmit == false)
        var submitCalled = false
        let submitted = await viewModel.submit(
            joinInvite: { _ in
                submitCalled = true
                return gameID
            },
            loadClaimSeatInvite: { _ in
                submitCalled = true
                return details
            }
        )

        #expect(submitted == nil)
        #expect(submitCalled == false)
        await gate.resume(with: gameID)
        #expect(await claimTask.value == gameID)
    }
}
