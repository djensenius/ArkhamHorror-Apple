@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("PublicGameSnapshot semantic presentation")
struct SnapshotSemanticPresentationTests {
    @Test("The semantic question map is parity-bound to the raw question and version")
    func questionPresentationBinds() throws {
        let game = try loadGetGame().game
        let playerID = try PlayerID(
            #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        )
        let presentation = try #require(game.questionPresentation?[playerID])
        let payload = try #require(game.question[playerID])
        let bound = try #require(payload.presentation)

        #expect(presentation.questionVersion == game.scenarioSteps)
        #expect(presentation.questionKind == .playerWindowChooseOne)
        #expect(presentation.choiceCount == 4)
        #expect(bound.presentation == presentation)
        #expect(bound.rawChoices.count == 4)
        #expect(bound.descriptor(forSourceIndex: 3)?.kind == .investigate)
    }

    @Test("A missing semantic map preserves the legacy raw-question fallback")
    func missingQuestionPresentationFallsBack() throws {
        let mutated = try mutateGetGame { game in
            game.removeValue(forKey: "questionPresentation")
        }
        let envelope = try ContractJSON.decode(GetGameEnvelope.self, from: mutated)
        #expect(envelope.game.questionPresentation == nil)
        #expect(envelope.game.question.values.allSatisfy { $0.presentation == nil })

        guard case let .object(root) = try LosslessJSONParser.parse(
            ContractJSON.encode(envelope)
        ),
            case let .object(game)? = root["game"]
        else {
            Issue.record("Expected an encoded GetGame object")
            return
        }
        #expect(game["questionPresentation"] == nil)
    }

    @Test("A present null semantic map fails instead of becoming legacy fallback")
    func nullQuestionPresentationFailsClosed() throws {
        let mutated = try mutateGetGame { game in
            game["questionPresentation"] = .null
        }
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(GetGameEnvelope.self, from: mutated)
        }
    }

    @Test("Semantic player keys must exactly match raw question player keys")
    func questionPresentationPlayerParityFailsClosed() throws {
        let mutated = try mutateGetGame { game in
            var presentations = try object(game["questionPresentation"])
            let originalKey = "00000000-0000-0000-0000-000000000001"
            let presentation = try required(presentations.removeValue(forKey: originalKey))
            presentations["00000000-0000-0000-0000-000000000002"] = presentation
            game["questionPresentation"] = .object(presentations)
        }
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(GetGameEnvelope.self, from: mutated)
        }
    }

    @Test("Semantic questionVersion drift marks only that prompt update-required")
    func questionPresentationVersionMismatchFailsClosed() throws {
        let mutated = try mutatePresentation { presentation in
            presentation["questionVersion"] = try jsonValue("4")
        }
        let envelope = try ContractJSON.decode(GetGameEnvelope.self, from: mutated)
        let playerID = try #require(envelope.playerID)
        let payload = try #require(envelope.game.question[playerID])
        #expect(payload.presentation == nil)
        #expect(payload.isUpdateRequired)
        #expect(envelope.game.name.isEmpty == false)
    }

    @Test("A sparse semantic map entry marks only that player update-required")
    func sparseQuestionPresentationFailsClosed() throws {
        let otherKey = "00000000-0000-0000-0000-000000000002"
        let mutated = try mutateGetGame { game in
            var questions = try object(game["question"])
            var presentations = try object(game["questionPresentation"])
            let playerKey = "00000000-0000-0000-0000-000000000001"
            questions[otherKey] = questions[playerKey]
            presentations[otherKey] = presentations[playerKey]
            var presentation = try object(presentations[playerKey])
            guard case var .array(choices)? = presentation["choices"] else {
                throw FixtureMutationError.unexpectedShape
            }
            choices.remove(at: 2)
            presentation["choices"] = .array(choices)
            presentations[playerKey] = .object(presentation)
            game["question"] = .object(questions)
            game["questionPresentation"] = .object(presentations)
        }
        let envelope = try ContractJSON.decode(GetGameEnvelope.self, from: mutated)
        let playerID = try #require(envelope.playerID)
        let otherPlayerID = try PlayerID(#require(UUID(uuidString: otherKey)))
        let failedPayload = try #require(envelope.game.question[playerID])
        let otherPayload = try #require(envelope.game.question[otherPlayerID])
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)

        #expect(envelope.game.name.isEmpty == false)
        #expect(failedPayload.presentation == nil)
        #expect(failedPayload.isUpdateRequired)
        #expect(otherPayload.presentation != nil)
        #expect(projection.questions[otherPlayerID]?.presentation != nil)
    }

    private enum FixtureMutationError: Error {
        case unexpectedShape
    }

    private func loadGetGame() throws -> GetGameEnvelope {
        try ContractJSON.decode(GetGameEnvelope.self, from: fixtureData(named: "get-game"))
    }

    private func mutatePresentation(
        _ mutation: (inout [String: JSONValue]) throws -> Void
    ) throws -> Data {
        try mutateGetGame { game in
            var presentations = try object(game["questionPresentation"])
            let playerKey = "00000000-0000-0000-0000-000000000001"
            var presentation = try object(presentations[playerKey])
            try mutation(&presentation)
            presentations[playerKey] = .object(presentation)
            game["questionPresentation"] = .object(presentations)
        }
    }

    private func mutateGetGame(
        _ mutation: (inout [String: JSONValue]) throws -> Void
    ) throws -> Data {
        guard case var .object(root) = try LosslessJSONParser.parse(
            fixtureData(named: "get-game")
        ) else {
            throw FixtureMutationError.unexpectedShape
        }
        var game = try object(root["game"])
        try mutation(&game)
        root["game"] = .object(game)
        return try LosslessJSONSerializer.serialize(.object(root))
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

    private func object(_ value: JSONValue?) throws -> [String: JSONValue] {
        guard case let .object(object)? = value else {
            throw FixtureMutationError.unexpectedShape
        }
        return object
    }

    private func required<T>(_ value: T?) throws -> T {
        guard let value else { throw FixtureMutationError.unexpectedShape }
        return value
    }

    private func jsonValue(_ json: String) throws -> JSONValue {
        try LosslessJSONParser.parse(Data(json.utf8))
    }
}
