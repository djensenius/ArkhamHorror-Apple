@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Public game question-presentation binding")
struct PublicGameSnapshotPresentationBindingTests {
    @Test("A presentation binding mismatch surfaces as update-required prompt state")
    func bindingMismatchMarksPromptUpdateRequired() throws {
        var value = try fixtureValue("get-game")
        guard case let .object(root) = value,
              case let .object(game)? = root["game"],
              case let .string(playerID)? = root["playerId"],
              case let .object(presentations)? = game["questionPresentation"],
              case let .object(presentation)? = presentations[playerID],
              presentation["choiceCount"] == .number(.integer(4))
        else { throw TestFailure() }

        value = try EnemyAttackFixtures.applying(
            operation: "replace",
            path: ["game", "questionPresentation", playerID, "choiceCount"].map { Substring($0) },
            replacement: .number(.integer(3)),
            to: value
        )
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: ContractJSON.encode(value)
        )
        let ownerID = try #require(envelope.playerID)
        let payload = try #require(envelope.game.question[ownerID])

        #expect(payload.isUpdateRequired)
        #expect(payload.presentation == nil)
    }

    private func fixtureValue(_ name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixtureData(name))
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        return try Data(contentsOf: url)
    }
}
