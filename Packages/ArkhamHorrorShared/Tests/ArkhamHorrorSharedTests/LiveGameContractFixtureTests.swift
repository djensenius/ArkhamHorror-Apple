@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic coverage that a REST ``GetGameEnvelope`` snapshot and a WebSocket
/// ``BoardSnapshotUpdate`` snapshot -- decoded through the exact same governed
/// production fixture bytes and the exact same ``ContractJSON``/
/// ``BoardProjectionBuilder`` boundary the live-game session runner uses for both
/// transports -- produce an equal ``BoardProjection``, matching this contract
/// slice's "REST and socket snapshots must produce equivalent domain values/
/// projections" requirement.
@Suite("Live-game REST/WebSocket fixture equivalence")
struct LiveGameContractFixtureTests {
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

    @Test("The get-game fixture's snapshot re-encoded as a GameUpdate frame projects identically")
    func restSnapshotReencodedAsSocketFrameProjectsIdentically() throws {
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self, from: fixtureData(named: "get-game")
        )
        let restProjection = BoardProjectionBuilder.makeProjection(from: envelope.game)

        // Re-encodes the exact same decoded `PublicGameSnapshot` as a `GameUpdate`
        // WebSocket frame, then decodes it back through the socket-side contract
        // boundary (`BoardSnapshotUpdate`), proving both transports funnel through
        // an identical decode/projection pipeline for the same underlying snapshot.
        let socketPayload = try ContractJSON.encode(BoardSnapshotUpdate.snapshot(envelope.game))
        let update = try ContractJSON.decode(BoardSnapshotUpdate.self, from: socketPayload)
        guard case let .snapshot(socketSnapshot) = update else {
            Issue.record("Expected a decoded .snapshot case")
            return
        }
        let socketProjection = BoardProjectionBuilder.makeProjection(from: socketSnapshot)
        #expect(restProjection == socketProjection)
    }

    @Test("The governed game-update fixture decodes to a .snapshot case with a valid projection")
    func gameUpdateFixtureDecodesToASnapshot() throws {
        let update = try ContractJSON.decode(
            BoardSnapshotUpdate.self, from: fixtureData(named: "game-update")
        )
        guard case let .snapshot(snapshot) = update else {
            Issue.record("Expected the governed game-update fixture to decode to .snapshot")
            return
        }
        // Merely constructing the projection must not throw/crash; this is the same
        // production pipeline `consumeLiveGameSocket` runs for every real frame.
        _ = BoardProjectionBuilder.makeProjection(from: snapshot)
    }

    @Test("An unrecognized ServerMessage tag decodes to .unsupportedMessage, never a decode error")
    func unrecognizedServerMessageTagDecodesToUnsupportedMessage() throws {
        let json = """
        {"tag":"SomeOtherMessage","contents":{"foo":1}}
        """
        let update = try ContractJSON.decode(BoardSnapshotUpdate.self, from: Data(json.utf8))
        guard case let .unsupportedMessage(tag, _) = update else {
            Issue.record("Expected .unsupportedMessage for an unrecognized tag")
            return
        }
        #expect(tag == "SomeOtherMessage")
    }

    @Test("Malformed GameUpdate contents throw, never silently decode to a placeholder")
    func malformedGameUpdateContentsThrows() {
        let json = """
        {"tag":"GameUpdate","contents":{"not":"a valid snapshot"}}
        """
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(BoardSnapshotUpdate.self, from: Data(json.utf8))
        }
    }
}
