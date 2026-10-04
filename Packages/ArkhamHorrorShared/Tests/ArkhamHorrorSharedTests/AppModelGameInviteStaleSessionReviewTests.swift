@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — game invite stale-session review fixes")
struct InviteStaleSessionReviewTests {
    @Test("joinGameFromInvite rejects stale GET join failures after session changes")
    func joinGameFromInviteRejectsStalePreviewFailure() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.setPeekLobbyGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let joinTask = Task { try await model.joinGameFromInvite(gameID) }
        await service.waitUntilPeekLobbyPending(1)
        model.generation += 1
        model.resetGameLifecycleState()
        await service.resumeOldestPeekLobby(
            with: .failure(GameLifecycleError.unexpectedStatus(500))
        )

        await #expect(throws: CancellationError.self) {
            try await joinTask.value
        }
        #expect(await service.callOrder == ["peekLobby"])
    }

    @Test("joinGameFromInvite rejects stale PUT join failures after session changes")
    func joinGameFromInviteRejectsStaleJoinFailure() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.success(.game(gameID)))
        await service.setJoinGameGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let joinTask = Task { try await model.joinGameFromInvite(gameID) }
        await service.waitUntilJoinGamePending(1)
        model.generation += 1
        model.resetGameLifecycleState()
        await service.resumeOldestJoinGame(
            with: .failure(GameLifecycleError.unexpectedStatus(500))
        )

        await #expect(throws: CancellationError.self) {
            try await joinTask.value
        }
        #expect(await service.callOrder == ["peekLobby", "joinGame"])
    }

    @Test("joinGameFromInvite revalidates after handling a session-expired join failure")
    func joinGameFromInviteRejectsAfterSessionExpiredHandler() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.success(.game(gameID)))
        await service.enqueueJoinGameResult(.failure(GameLifecycleError.sessionExpired))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        await #expect(throws: CancellationError.self) {
            try await model.joinGameFromInvite(gameID)
        }
        #expect(await service.callOrder == ["peekLobby", "joinGame"])
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }

    @Test("claim-seat invite rejects stale GET join failures after session changes")
    func claimSeatInviteRejectsStalePreviewFailure() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.setPeekLobbyGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let loadTask = Task { try await model.loadClaimSeatInvite(gameID) }
        await service.waitUntilPeekLobbyPending(1)
        model.generation += 1
        model.resetGameLifecycleState()
        await service.resumeOldestPeekLobby(
            with: .failure(GameLifecycleError.unexpectedStatus(500))
        )

        await #expect(throws: CancellationError.self) {
            _ = try await loadTask.value
        }
        #expect(await service.callOrder == ["peekLobby"])
    }

    @Test("claim-seat invite rejects stale open-seat failures after session changes")
    func claimSeatInviteRejectsStaleOpenSeatsFailure() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.success(.game(gameID, playerCount: 2)))
        await service.setOpenSeatsGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let loadTask = Task { try await model.loadClaimSeatInvite(gameID) }
        await service.waitUntilOpenSeatsPending(1)
        model.generation += 1
        model.resetGameLifecycleState()
        await service.resumeOldestOpenSeats(
            with: .failure(GameLifecycleError.unexpectedStatus(500))
        )

        await #expect(throws: CancellationError.self) {
            _ = try await loadTask.value
        }
        #expect(await service.callOrder == ["peekLobby", "openSeats"])
    }

    @Test("claim-seat invite rejects stale membership lookup failures after session changes")
    func claimSeatInviteRejectsStaleMembershipFailure() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let seat = try CardCode("c01001")
        await service.enqueuePeekLobbyResult(.success(.game(gameID, playerCount: 2)))
        await service.enqueueOpenSeatsResult(.success([seat]))
        await service.setGetGameGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        let loadTask = Task { try await model.loadClaimSeatInvite(gameID) }
        await service.waitUntilGetGamePending(1)
        model.generation += 1
        model.resetGameLifecycleState()
        await service.resumeOldestGetGame(
            with: .failure(GameLifecycleError.unexpectedStatus(500))
        )

        await #expect(throws: CancellationError.self) {
            _ = try await loadTask.value
        }
        #expect(await service.callOrder == ["peekLobby", "openSeats", "getGame"])
    }

    @Test("claim-seat invite revalidates after handling a session-expired load failure")
    func claimSeatInviteRejectsAfterSessionExpiredHandler() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueuePeekLobbyResult(.failure(GameLifecycleError.sessionExpired))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        await #expect(throws: CancellationError.self) {
            _ = try await model.loadClaimSeatInvite(gameID)
        }
        #expect(await service.callOrder == ["peekLobby"])
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }
}
