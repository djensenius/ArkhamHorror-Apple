@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("RoomClosed message validation")
struct RoomClosedMessageValidationTests {
    private struct MalformedRoomClosedFrame {
        let name: String
        let bytes: Data
        let expectedUpdate: BoardSnapshotUpdate
    }

    @Test("Malformed RoomClosed frames are unsupported and do not close the current room")
    func malformedRoomClosedFramesAreUnsupportedAndNonTerminal() async throws {
        for frame in malformedRoomClosedFrames() {
            try await assertUnsupportedAndNonTerminal(frame)
        }
    }

    private func malformedRoomClosedFrames() -> [MalformedRoomClosedFrame] {
        [
            MalformedRoomClosedFrame(
                name: "missing contents",
                bytes: Data(#"{"tag":"RoomClosed"}"#.utf8),
                expectedUpdate: .unsupportedMessage(tag: "RoomClosed", rawContents: nil)
            ),
            MalformedRoomClosedFrame(
                name: "number contents",
                bytes: Data(#"{"tag":"RoomClosed","contents":404}"#.utf8),
                expectedUpdate: .unsupportedMessage(
                    tag: "RoomClosed",
                    rawContents: .number(.integer(404))
                )
            ),
            MalformedRoomClosedFrame(
                name: "object contents",
                bytes: Data(#"{"tag":"RoomClosed","contents":{"reason":"deleted"}}"#.utf8),
                expectedUpdate: .unsupportedMessage(
                    tag: "RoomClosed",
                    rawContents: .object(["reason": .string("deleted")])
                )
            ),
        ]
    }

    private func assertUnsupportedAndNonTerminal(
        _ frame: MalformedRoomClosedFrame
    ) async throws {
        let update = try ContractJSON.decode(BoardSnapshotUpdate.self, from: frame.bytes)
        #expect(update == frame.expectedUpdate, "\(frame.name) should remain unsupported")

        let harness = AppModelLiveGameTests()
        let (model, _) = harness.makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = harness.installCurrentAttempt(for: gameID, on: model)
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: fixtureData(named: "get-game")
        )
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        let connection = FakeGameSocketConnection()
        await connection.enqueue(.event(.message(frame.bytes)))
        await connection.enqueue(.event(.closed(code: .normalClosure, reason: nil)))

        _ = await model.consumeLiveGameSocket(
            attempt,
            connection: connection,
            projection: projection
        )
        #expect(!model.confirmedDeletedGameIDs.contains(gameID))
        #expect(model.roomClosedNotice == nil)
        assertNoRouteChange(for: gameID, on: model)
        await connection.waitUntilClosed()
    }

    private func assertNoRouteChange(for gameID: GameID, on model: AppModel) {
        var presentedGameID: GameID?
        var liveGamePath = [gameID]
        OpenGameSurfaceReconciler.reconcile(
            presentedGameID: &presentedGameID,
            liveGamePath: &liveGamePath,
            gameListState: .loading(previous: nil),
            confirmedDeletedGameIDs: model.confirmedDeletedGameIDs
        )
        #expect(liveGamePath == [gameID])
    }

    private func fixtureData(named fileName: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: fileName,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }
}
