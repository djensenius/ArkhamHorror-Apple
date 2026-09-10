@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Basic investigation controls")
struct BasicChoiceInvestigationTests {
    private let cardIDText = "00000000-0000-0000-0000-0000000003c3"

    @Test("Exact skip, start, and apply controls decode without a messages payload")
    func exactControlsDecode() throws {
        let skip = try firstChoice(
            #"""
            {
              "tag":"WindowChooseOne",
              "choices":[{"tag":"SkipTriggersButton","investigatorId":"c01001"}]
            }
            """#
        )
        let start = try firstChoice(
            #"""
            {
              "tag":"ChooseOne",
              "choices":[{"tag":"StartSkillTestButton","investigatorId":"c01001"}]
            }
            """#
        )
        let apply = try firstChoice(
            #"""
            {
              "tag":"ChooseOne",
              "choices":[{"tag":"SkillTestApplyResultsButton"}]
            }
            """#
        )

        guard case let .skipTriggers(investigatorID) = skip.content else {
            Issue.record("Expected SkipTriggersButton")
            return
        }
        #expect(investigatorID.rawValue.rawValue == "c01001")
        guard case let .startSkillTest(investigatorID) = start.content else {
            Issue.record("Expected StartSkillTestButton")
            return
        }
        #expect(investigatorID.rawValue.rawValue == "c01001")
        #expect(apply.content == .applySkillTestResults)
    }

    @Test(
        "Malformed controls remain visible and unsupported",
        arguments: [
            #"{"tag":"SkipTriggersButton"}"#,
            #"{"tag":"SkipTriggersButton","investigatorID":"c01001"}"#,
            #"{"tag":"SkipTriggersButton","investigatorId":"C01001"}"#,
            #"{"tag":"SkipTriggersButton","investigatorId":"c01001","messages":[]}"#,
            #"{"tag":"SkipTriggersButton","investigatorId":"c01001","extra":true}"#,
            #"{"tag":"StartSkillTestButton"}"#,
            #"{"tag":"StartSkillTestButton","investigatorID":"c01001"}"#,
            #"{"tag":"StartSkillTestButton","investigatorId":"C01001"}"#,
            #"{"tag":"StartSkillTestButton","investigatorId":"c01001","messages":[]}"#,
            #"{"tag":"StartSkillTestButton","investigatorId":"c01001","extra":true}"#,
            #"{"tag":"SkillTestApplyResultsButton","messages":[]}"#,
            #"{"tag":"SkillTestApplyResultsButton","extra":true}"#,
        ]
    )
    func malformedControlsFailClosed(choiceJSON: String) throws {
        let choice = try firstChoice(
            #"{"tag":"ChooseOne","choices":[\#(choiceJSON)]}"#
        )
        #expect(choice.index == 0)
        #expect(!choice.isSupported)
        #expect(choice.content == .unsupported(tag: choiceTag(choiceJSON)))
    }

    @Test("Card targets use prompt-shape context for play and commit labels")
    func cardPurposeUsesPromptShape() throws {
        let playQuestion = try question(
            """
            {"tag":"WindowChooseOne","choices":[\
            \(cardTarget),\
            {"tag":"SkipTriggersButton","investigatorId":"c01001"}]}
            """
        )
        let commitQuestion = try question(
            """
            {"tag":"ChooseOne","choices":[\
            \(cardTarget),\
            {"tag":"StartSkillTestButton","investigatorId":"c01001"}]}
            """
        )
        guard case let .chooseHandCard(_, playPurpose, _) = playQuestion.choices[0].content,
              case let .chooseHandCard(_, commitPurpose, _) = commitQuestion.choices[0].content
        else {
            Issue.record("Expected CardIdTarget choices")
            return
        }
        #expect(playPurpose == .play)
        #expect(commitPurpose == .commit)

        let ownerID = BoardTestFixtures.playerID()
        let projection = try projection(ownerID: ownerID)
        #expect(BoardDisplayFormatting.choiceDisplayTitle(
            for: playQuestion.choices[0],
            in: projection,
            ownerID: ownerID
        ) == "Play Card c01030")
        #expect(BoardDisplayFormatting.choiceDisplayTitle(
            for: commitQuestion.choices[0],
            in: projection,
            ownerID: ownerID
        ) == "Commit Card c01030")
    }

    @Test("Focus skips an unsupported sibling without renumbering backend choices")
    func focusPreservesSourceIndices() throws {
        let rawQuestion = """
        {"tag":"WindowChooseOne","choices":[\
        \(cardTarget),\
        {"tag":"SkipTriggersButton","investigatorId":"c01001","messages":[]},\
        {"tag":"SkipTriggersButton","investigatorId":"c01001"}]}
        """
        let payload = try payload(rawQuestion)
        let question = try #require(payload.supportedQuestion)
        let ownerID = BoardTestFixtures.playerID()
        let projection = try projection(ownerID: ownerID)
        let presentation = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: ownerID,
                questionVersion: 9,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            choiceLabelResolutions: [:],
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil,
            catalogRetry: nil
        )
        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: presentation,
            onChoice: { submitted.append($0) }
        )

        #expect(question.choices.map(\.index) == [0, 1, 2])
        #expect(question.choices.map(\.isSupported) == [true, false, true])
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(1)))
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptChoice(2)))
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(controller.activatePromptChoice(2))
        #expect(submitted == [0, 2])
    }

    private var cardTarget: String {
        """
        {"tag":"TargetLabel","target":{"tag":"CardIdTarget","contents":"\(cardIDText)"},\
        "messages":[{"tag":"InvestigatorMessage","contents":{}}]}
        """
    }

    private func payload(_ json: String) throws -> BasicChoiceQuestionPayload {
        try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: Data(json.utf8)
        )
    }

    private func question(_ json: String) throws -> BasicChoiceQuestion {
        try #require(payload(json).supportedQuestion)
    }

    private func firstChoice(_ json: String) throws -> BasicChoice {
        try #require(question(json).choices.first)
    }

    private func choiceTag(_ json: String) -> String? {
        guard let value = try? ContractJSON.decode(JSONValue.self, from: Data(json.utf8)),
              case let .object(object) = value,
              case let .string(tag)? = object["tag"]
        else { return nil }
        return tag
    }

    private func projection(ownerID: PlayerID) throws -> BoardProjection {
        let cardID = try #require(WireCardID(
            codingKey: AnyCodingKey(stringValue: cardIDText)
        ))
        let card: JSONValue = .object([
            "tag": .string("PlayerCard"),
            "contents": .object([
                "id": .string(cardIDText),
                "cardCode": .string("c01030"),
            ]),
        ])
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    hand: [card],
                    playerID: ownerID
                ),
            ],
            playerOrder: [investigatorID],
            activeInvestigatorID: investigatorID,
            leadInvestigatorID: investigatorID,
            cardValues: [cardID: card]
        ))
    }
}
