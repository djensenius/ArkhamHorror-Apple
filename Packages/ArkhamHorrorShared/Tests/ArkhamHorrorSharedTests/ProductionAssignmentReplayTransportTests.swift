@testable import ArkhamHorrorShared
import Testing

@Suite("Production assignment replay transport")
struct ProductionAssignmentReplayTransportTests {
    @Test("Authoritative snapshots are coalesced and bounded")
    func authoritativeSnapshotsAreBounded() async throws {
        let recorder = AssignmentReplayAuthoritativeRecorder(
            maximumObservationCount: 2
        )
        try await recorder.recordSocket(snapshot(name: "first", version: 34))
        try await recorder.recordSocket(
            snapshot(name: "replacement", version: 34)
        )

        let replacement = await recorder.latest(
            gameID: BoardTestFixtures.gameID(),
            questionVersion: 34,
            source: .socket
        )
        #expect(replacement?.snapshot.name == "replacement")

        try await recorder.recordSocket(snapshot(name: "second", version: 35))
        try await recorder.recordSocket(snapshot(name: "third", version: 36))

        let evicted = await recorder.latest(
            gameID: BoardTestFixtures.gameID(),
            questionVersion: 34,
            source: .socket
        )
        let second = await recorder.latest(
            gameID: BoardTestFixtures.gameID(),
            questionVersion: 35,
            source: .socket
        )
        let third = await recorder.latest(
            gameID: BoardTestFixtures.gameID(),
            questionVersion: 36,
            source: .socket
        )
        #expect(evicted == nil)
        #expect(second?.snapshot.name == "second")
        #expect(third?.snapshot.name == "third")
    }

    private func snapshot(
        name: String,
        version: Int
    ) throws -> PublicGameSnapshot {
        let encoded = try ContractJSON.encode(
            BoardTestFixtures.snapshot(name: name)
        )
        let value = try ContractJSON.decode(JSONValue.self, from: encoded)
        guard case var .object(root) = value else { throw TestFailure() }
        root["scenarioSteps"] = .number(.integer(Int64(version)))
        return try ContractJSON.decode(
            PublicGameSnapshot.self,
            from: ContractJSON.encode(JSONValue.object(root))
        )
    }
}
