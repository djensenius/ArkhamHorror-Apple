@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Public game question-presentation binding")
struct PublicGamePresentationBindingTests {
    @Test("A presentation binding mismatch surfaces as update-required prompt state")
    func bindingMismatchMarksPromptUpdateRequired() throws {
        var value = try fixtureValue("get-game")
        guard case let .object(root) = value,
              case let .object(game)? = root["game"],
              case let .string(playerID)? = root["playerId"],
              case let .object(questions)? = game["question"],
              case let .object(rawQuestion)? = questions[playerID],
              case let .array(rawChoices)? = rawQuestion["choices"],
              rawChoices.count == 4,
              case let .object(presentations)? = game["questionPresentation"],
              case let .object(presentation)? = presentations[playerID],
              presentation["choiceCount"] == .number(.integer(4)),
              case let .array(presentationChoices)? = presentation["choices"],
              presentationChoices.count == 4
        else { throw TestFailure() }

        value = try EnemyAttackFixtures.applying(
            operation: "remove",
            path: ["game", "question", playerID, "choices", "3"].map { Substring($0) },
            replacement: nil,
            to: value
        )
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: ContractJSON.encode(value)
        )
        let ownerID = try #require(envelope.playerID)
        let decodedPresentation = try #require(envelope.game.questionPresentation?[ownerID])
        let payload = try #require(envelope.game.question[ownerID])
        guard case let .object(decodedRawQuestion) = payload.rawValue,
              case let .array(decodedRawChoices)? = decodedRawQuestion["choices"]
        else { throw TestFailure() }

        #expect(decodedRawChoices.count == 3)
        #expect(decodedPresentation.choiceCount == 4)
        #expect(decodedPresentation.choices.map(\.sourceIndex) == [0, 1, 2, 3])
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
