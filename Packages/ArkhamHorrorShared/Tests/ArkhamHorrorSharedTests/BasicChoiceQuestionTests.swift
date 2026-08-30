@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Basic choice contract")
struct BasicChoiceQuestionTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name, withExtension: "json", subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    @Test(
        "All three question tags decode, and choice labels retain their exact array indices",
        arguments: [
            ("question-choose-one", BasicChoiceQuestionKind.chooseOne, ["End turn"]),
            (
                "question-player-window-choose-one",
                BasicChoiceQuestionKind.playerWindowChooseOne,
                ["Gain a resource", "Draw a card", "End turn", "Investigate"]
            ),
            ("question-window-choose-one", BasicChoiceQuestionKind.windowChooseOne, ["End turn"]),
        ]
    )
    func fixturesDecode(
        name: String, kind: BasicChoiceQuestionKind, labels: [String]
    ) throws {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture(name)
        )
        let question = try #require(payload.supportedQuestion)
        #expect(question.kind == kind)
        #expect(question.choices.map(\.index) == Array(labels.indices))
        #expect(question.choices.map(\.title) == labels)
        // swiftformat:disable:next preferKeyPath
        #expect(question.choices.allSatisfy { $0.isSupported })
    }

    @Test("AbilityLabel retains all engine-owned fields losslessly")
    func abilityRetainsRawEngineData() throws {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: fixture("question-player-window-choose-one")
        )
        let ability = try #require(payload.supportedQuestion?.choices.last?.ability)
        #expect(ability.investigatorID.rawValue.rawValue == "c01001")
        #expect(ability.cardCode.rawValue == "c01111")
        #expect(ability.windows.count == 3)
        #expect(ability.before.isEmpty)
        #expect(ability.messages.isEmpty)
        guard case let .object(rawAbility) = ability.rawAbility else {
            Issue.record("Expected the full ability object")
            return
        }
        #expect(rawAbility["criteria"] != nil)
        #expect(rawAbility["source"] != nil)
        #expect(rawAbility["type"] != nil)
    }

    // Governed malformed JSON remains legible as exact one-line token streams.
    // swiftlint:disable line_length
    @Test(
        "Malformed, aliased, cross-variant, and unknown choices remain visible but unsupported",
        arguments: [
            #"{"tag":"EndTurnButton","investigatorID":"c01001","messages":[]}"#,
            #"{"tag":"EndTurnButton","investigatorId":"C01001","messages":[]}"#,
            #"{"tag":"EndTurnButton","investigatorId":"c01001","messages":{}}"#,
            #"{"tag":"ComponentLabel","investigatorId":"c01001","messages":[]}"#,
            #"{"tag":"ComponentLabel","component":{"tag":"InvestigatorComponent","investigatorId":"c01001","tokenType":"ClueToken"},"messages":[]}"#,
            #"{"tag":"AbilityLabel","investigatorId":"c01001","ability":{"source":{},"cardCode":"c01111","index":103,"type":{"tag":"ActionAbility","actions":{"tag":"SingleAction","contents":"Fight"}}},"windows":[],"before":[],"messages":[]}"#,
            #"{"tag":"FutureChoice","messages":[{"tag":"DoSomething"}]}"#,
        ]
    )
    func invalidChoicesFailClosed(choiceJSON: String) throws {
        let bytes = Data(
            #"{"tag":"ChooseOne","choices":[\#(choiceJSON)]}"#.utf8
        )
        let payload = try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: bytes)
        let choice = try #require(payload.supportedQuestion?.choices.first)
        #expect(choice.index == 0)
        #expect(!choice.isSupported)
        #expect(choice.title == "Update required")
    }

    @Test("Engine-owned message values remain lossless and do not drive presentation")
    func nestedMessagesRemainOpaque() throws {
        let data = Data(
            #"{"tag":"ChooseOne","choices":[{"tag":"EndTurnButton","investigatorId":"c01001","messages":[42,"future",null]}]}"#
                .utf8
        )
        let payload = try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: data)
        let choice = try #require(payload.supportedQuestion?.choices.first)
        #expect(choice.isSupported)
        #expect(choice.title == "End turn")
        guard case let .endTurn(_, messages) = choice.content else {
            Issue.record("Expected EndTurnButton")
            return
        }
        #expect(messages == [.number(.integer(42)), .string("future"), .null])
    }

    @Test(
        "Malformed or unknown question shapes become explicit unsupported state",
        arguments: [
            #"{"tag":"ChooseOne","choices":[]}"#,
            #"{"tag":"ChooseOne","choices":[{"tag":"EndTurnButton","investigatorId":"c01001","messages":[]}],"extra":true}"#,
            #"{"tag":"ChooseOne","choice":[]}"#,
            #"{"tag":"FutureQuestion","choices":[]}"#,
            #"{"choices":[]}"#,
            #"[]"#,
        ]
    )
    func invalidQuestionsFailClosed(json: String) throws {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: Data(json.utf8)
        )
        #expect(payload.supportedQuestion == nil)
        #expect(payload.isUpdateRequired)
    }

    @Test("The governed Answer fixture decodes and re-encodes to exact canonical bytes")
    func exactAnswerBytes() throws {
        let decoded = try ContractJSON.decode(
            BasicChoiceAnswer.self, from: fixture("answer-question")
        )
        #expect(decoded.choice == 2)
        #expect(decoded.questionVersion == 3)
        #expect(decoded.playerID.rawValue.uuidString.lowercased()
            == "00000000-0000-0000-0000-000000000001")
        let encoded = try ContractJSON.encode(decoded)
        #expect(encoded == Data(
            #"{"contents":{"choice":2,"playerId":"00000000-0000-0000-0000-000000000001","questionVersion":3},"tag":"Answer"}"#.utf8
        ))
    }

    @Test(
        "Answer decoding rejects aliases, negative/fractional integers, and noncanonical UUIDs",
        arguments: [
            #"{"tag":"Answer","contents":{"choice":-1,"playerId":"00000000-0000-0000-0000-000000000001","questionVersion":3}}"#,
            #"{"tag":"Answer","contents":{"choice":0.0,"playerId":"00000000-0000-0000-0000-000000000001","questionVersion":3}}"#,
            #"{"tag":"Answer","contents":{"choice":0,"playerId":"AAAAAAAA-0000-0000-0000-000000000001","questionVersion":3}}"#,
            #"{"tag":"Answer","contents":{"choice":0,"playerID":"00000000-0000-0000-0000-000000000001","questionVersion":3}}"#,
            #"{"tag":"Answer","contents":{"choice":0,"playerId":"00000000-0000-0000-0000-000000000001","questionVersion":03}}"#,
        ]
    )
    func invalidAnswersAreRejected(json: String) {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(BasicChoiceAnswer.self, from: Data(json.utf8))
        }
    }

    @Test("Answer encoding rejects negative runtime integers")
    func invalidAnswerEncodingIsRejected() {
        let answer = BasicChoiceAnswer(
            choice: -1,
            playerID: BoardTestFixtures.playerID(),
            questionVersion: 3
        )
        #expect(throws: (any Error).self) {
            try ContractJSON.encode(answer)
        }
    }
    // swiftlint:enable line_length
}
