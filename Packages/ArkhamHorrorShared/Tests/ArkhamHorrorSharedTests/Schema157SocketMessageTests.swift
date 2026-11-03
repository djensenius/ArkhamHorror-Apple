@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Schema 0.1.57 WebSocket additions. The three captured messages in
/// `Fixtures/Schema157Drift` must stay non-fatal unsupported frames, and the new
/// `RoomClosed` reasons end the room without treating the still-existing game as deleted.
@MainActor
@Suite("Schema 0.1.57 WebSocket messages")
struct Schema157SocketMessageTests {
    @Test("Captured 0.1.57 socket messages decode as unsupported frames")
    func capturedMessagesAreUnsupported() throws {
        let expected: [(String, BoardSnapshotUpdate)] = [
            ("game-watcher-count", .unsupportedMessage(
                tag: "GameWatcherCount", rawContents: .number(.integer(2))
            )),
            ("game-unarchived", .unsupportedMessage(tag: "GameUnarchived", rawContents: nil)),
            ("game-unarchive-failed", .unsupportedMessage(
                tag: "GameUnarchiveFailed",
                rawContents: .string("The archived steps could not be restored.")
            )),
        ]
        for (name, update) in expected {
            let decoded = try ContractJSON.decode(
                BoardSnapshotUpdate.self, from: Schema157Fixtures.data(name)
            )
            #expect(decoded == update, "\(name)")
        }
    }

    @Test("Captured 0.1.57 socket messages leave the live room open and keep reading")
    func capturedMessagesKeepTheSocketOpen() async throws {
        let frames = try ["game-watcher-count", "game-unarchived", "game-unarchive-failed"]
            .map(Schema157Fixtures.data)
        let snapshot = try Schema157Fixtures.contractData("game-update")
        let harness = AppModelLiveGameTests()
        let (model, _) = harness.makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = harness.installCurrentAttempt(for: gameID, on: model)
        let connection = FakeGameSocketConnection()
        for frame in frames {
            await connection.enqueue(.event(.message(frame)))
        }
        await connection.enqueue(.event(.message(snapshot)))
        await connection.enqueue(.event(.closed(code: .normalClosure, reason: nil)))

        _ = try await model.consumeLiveGameSocket(
            attempt, connection: connection, projection: Self.projection()
        )
        guard case .live = model.liveGameState(for: gameID) else {
            Issue.record("Expected the GameUpdate after the unsupported frames to apply")
            return
        }
        #expect(model.roomClosedNotice == nil)
        #expect(!model.confirmedDeletedGameIDs.contains(gameID))
    }

    /// Only `deleted` deletes the game. The sync candidate also closes rooms whose game
    /// still exists: `abandoned` and `maintenance` (Api/Arkham/Helpers.hs:972, :1018) and an
    /// admin `swept` (Api/Handler/Arkham/Games/Admin.hs:442). Unknown reasons are treated
    /// the same way, as the conservative choice.
    @Test("RoomClosed reasons other than deleted end the room but keep the game listed")
    func nonDeletingRoomClosedReasonsKeepTheGame() async throws {
        let reopen = "The server closed this game's room. Reopen it to continue."
        let cases = [
            ("abandoned", "Every player left this game, so the server closed its room."),
            (
                "maintenance",
                "The server is down for maintenance. Open the game again once it is back."
            ),
            ("swept", reopen),
            ("some-future-reason", reopen),
        ]
        for (reason, message) in cases {
            let closed = try await Self.closeRoom(reason: reason)
            let model = closed.model
            #expect(closed.outcome == .stopped, "\(reason)")
            #expect(model.liveGameState(for: closed.gameID) == .roomClosed(
                reason: reason, lastKnown: closed.projection
            ))
            #expect(!model.liveGameState(for: closed.gameID).isRetryable, "\(reason)")
            #expect(!model.confirmedDeletedGameIDs.contains(closed.gameID), "\(reason)")
            #expect(model.roomClosedNotice == nil, "\(reason)")
            #expect(liveGameRoomClosedMessage(reason: reason) == message, "\(reason)")
        }
    }

    @Test("RoomClosed deleted still removes the game and leaves a list notice")
    func deletedRoomClosedRemovesTheGame() async throws {
        let closed = try await Self.closeRoom(reason: "deleted")
        let model = closed.model
        #expect(closed.outcome == .stopped)
        #expect(model.confirmedDeletedGameIDs.contains(closed.gameID))
        #expect(model.roomClosedNotice == RoomClosedNotice(
            gameID: closed.gameID, reason: "deleted"
        ))
        #expect(model.liveGameState(for: closed.gameID) == .roomClosed(
            reason: "deleted", lastKnown: closed.projection
        ))
        #expect(liveGameRoomClosedMessage(reason: "deleted") == liveGameRoomClosedMessage())
        #expect(liveGameRoomClosedMessage() == "This game was closed on the server.")
    }

    private struct ClosedRoom {
        let model: AppModel
        let gameID: GameID
        let projection: BoardProjection
        let outcome: LiveGameSocketConsumeOutcome
    }

    /// Feeds one synthetic `{"tag":"RoomClosed","contents":<reason>}` frame, encoded like
    /// the captured Contract room-closed.json, to a live socket.
    private static func closeRoom(reason: String) async throws -> ClosedRoom {
        let bytes = Data(#"{"tag":"RoomClosed","contents":"\#(reason)"}"#.utf8)
        let update = try ContractJSON.decode(BoardSnapshotUpdate.self, from: bytes)
        #expect(update == .roomClosed(reason: reason))

        let harness = AppModelLiveGameTests()
        let (model, _) = harness.makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = harness.installCurrentAttempt(for: gameID, on: model)
        let projection = try projection()
        let connection = FakeGameSocketConnection()
        await connection.enqueue(.event(.message(bytes)))
        let outcome = await model.consumeLiveGameSocket(
            attempt, connection: connection, projection: projection
        )
        await connection.waitUntilClosed()
        return ClosedRoom(model: model, gameID: gameID, projection: projection, outcome: outcome)
    }

    private static func projection() throws -> BoardProjection {
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self, from: Schema157Fixtures.contractData("get-game")
        )
        return BoardProjectionBuilder.makeProjection(from: envelope.game)
    }
}
