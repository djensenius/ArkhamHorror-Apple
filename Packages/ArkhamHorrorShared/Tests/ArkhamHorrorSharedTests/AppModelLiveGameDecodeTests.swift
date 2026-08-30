@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Continuation of `AppModelLiveGameTests.swift`, split purely to respect this
/// package's file/type-length lint limits: decode-failure classification for
/// `consumeLiveGameSocket`'s own frame handling. Shares the same fixtures/fakes/
/// helpers declared in the primary file via this `extension`.
extension AppModelLiveGameTests {
    // MARK: - Decode failure

    @Test("A malformed WebSocket frame publishes incompatiblePayload and closes the socket once")
    func malformedSocketFramePublishesIncompatiblePayload() async throws {
        let (model, _) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = installCurrentAttempt(for: gameID, on: model)
        let envelope = try loadGetGame()
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        model.liveGameStates[gameID] = .live(projection)

        let connection = FakeGameSocketConnection()
        await connection.enqueue(.event(.message(Data("not valid contract json".utf8))))

        let outcome = await model.consumeLiveGameSocket(
            attempt, connection: connection, projection: projection
        )
        #expect(outcome == .stopped)
        #expect(model.liveGameState(for: gameID) == .incompatiblePayload(lastKnown: projection))
        await connection.waitUntilClosed()
        let closeCount = await connection.closeCallCount
        #expect(closeCount == 1)
    }

    @Test("An unsupported ServerMessage tag is ignored, never treated as an incompatibility")
    func unsupportedServerMessageIsIgnored() async throws {
        let (model, _) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = installCurrentAttempt(for: gameID, on: model)
        let envelope = try loadGetGame()
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)

        let connection = FakeGameSocketConnection()
        let unsupportedJSON = Data("""
        {"tag":"SomethingElse","contents":null}
        """.utf8)
        await connection.enqueue(.event(.message(unsupportedJSON)))
        await connection.enqueue(.event(.closed(code: .normalClosure, reason: nil)))

        let outcome = await model.consumeLiveGameSocket(
            attempt, connection: connection, projection: projection
        )
        #expect(outcome == .lost(projection))
        // Never overwritten to `.incompatiblePayload` by the ignored frame.
        #expect(model.liveGameState(for: gameID) != .incompatiblePayload(lastKnown: projection))
    }

    @Test("A valid WebSocket snapshot frame publishes live with the exact decoded projection")
    func validSocketSnapshotPublishesLive() async throws {
        let (model, _) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = installCurrentAttempt(for: gameID, on: model)
        let envelope = try loadGetGame()
        let initialProjection = BoardProjectionBuilder.makeProjection(from: envelope.game)

        let connection = FakeGameSocketConnection()
        let update = try loadGameUpdateData()
        await connection.enqueue(.event(.message(update)))
        await connection.enqueue(.event(.closed(code: .normalClosure, reason: nil)))

        _ = await model.consumeLiveGameSocket(
            attempt, connection: connection, projection: initialProjection
        )
        let decodedUpdate = try ContractJSON.decode(BoardSnapshotUpdate.self, from: update)
        guard case let .snapshot(snapshot) = decodedUpdate else {
            Issue.record("Expected the game-update fixture to decode to .snapshot")
            return
        }
        let expected = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(model.liveGameState(for: gameID) == .live(expected))
    }
}
