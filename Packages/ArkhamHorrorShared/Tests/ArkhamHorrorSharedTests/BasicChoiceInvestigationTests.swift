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

@MainActor
extension BasicChoiceInvestigationTests {
    @Test("Production fixtures decode the authoritative investigation prompt sequence")
    func productionFixturesDecode() throws {
        let fastWindow = try fixtureQuestion("question-investigate-fast-window")
        let commit = try fixtureQuestion("question-investigate-commit")
        let revealWindow = try fixtureQuestion("question-investigate-reveal-window")
        let applyResults = try fixtureQuestion("question-investigate-apply-results")

        #expect(fastWindow.kind == .windowChooseOne)
        #expect(commit.kind == .chooseOne)
        #expect(revealWindow.kind == .windowChooseOne)
        #expect(applyResults.kind == .chooseOne)
        #expect(fastWindow.choices.map(\.index) == [0, 1])
        #expect(commit.choices.map(\.index) == [0, 1])
        #expect(revealWindow.choices.map(\.index) == [0, 1])
        #expect(applyResults.choices.map(\.index) == [0])
        #expect(fastWindow.choices.map(\.isSupported) == [true, true])
        #expect(commit.choices.map(\.isSupported) == [true, true])
        #expect(revealWindow.choices.map(\.isSupported) == [true, true])
        #expect(applyResults.choices.map(\.isSupported) == [true])

        expectHandCard(fastWindow.choices[0], purpose: .play)
        expectInvestigatorControl(fastWindow.choices[1], expectedTag: "skip")
        expectHandCard(commit.choices[0], purpose: .commit)
        expectInvestigatorControl(commit.choices[1], expectedTag: "start")
        expectHandCard(revealWindow.choices[0], purpose: .play)
        expectInvestigatorControl(revealWindow.choices[1], expectedTag: "skip")
        #expect(applyResults.choices[0].content == .applySkillTestResults)
    }

    @Test("Production fixture focus submits exact backend source indices")
    func productionFixtureFocusPreservesSourceIndices() throws {
        let ownerID = BoardTestFixtures.playerID()
        let board = try projection(ownerID: ownerID)
        let fixtures: [(String, [Int])] = [
            ("question-investigate-fast-window", [0, 1]),
            ("question-investigate-commit", [0, 1]),
            ("question-investigate-reveal-window", [0, 1]),
            ("question-investigate-apply-results", [0]),
        ]
        for (offset, fixture) in fixtures.enumerated() {
            try expectControllerSubmission(
                fixtureName: fixture.0,
                expectedIndices: fixture.1,
                questionVersion: 20 + offset,
                ownerID: ownerID,
                projection: board
            )
        }
    }

    private func expectControllerSubmission(
        fixtureName: String,
        expectedIndices: [Int],
        questionVersion: Int,
        ownerID: PlayerID,
        projection: BoardProjection
    ) throws {
        let payload = try fixturePayload(fixtureName)
        let question = try #require(payload.supportedQuestion)
        let firstIndex = try #require(expectedIndices.first)
        let presentation = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: ownerID,
                questionVersion: questionVersion,
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

        #expect(question.choices.map(\.index) == expectedIndices)
        for index in expectedIndices {
            #expect(controller.coordinator.graph.contains(BoardFocusID.promptChoice(index)))
        }
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(
            controller.coordinator.currentFocus
                == BoardFocusID.promptChoice(firstIndex)
        )
        #expect(controller.handle(.command(.primaryAction)))
        for index in expectedIndices.dropFirst() {
            #expect(controller.activatePromptChoice(index))
        }
        #expect(submitted == expectedIndices)
    }

    private func fixturePayload(_ name: String) throws -> BasicChoiceQuestionPayload {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: Data(contentsOf: url)
        )
    }

    private func fixtureQuestion(_ name: String) throws -> BasicChoiceQuestion {
        try #require(fixturePayload(name).supportedQuestion)
    }

    private func expectHandCard(
        _ choice: BasicChoice, purpose: BasicChoiceHandCardPurpose
    ) {
        guard case let .chooseHandCard(cardID, actualPurpose, _) = choice.content else {
            Issue.record("Expected CardIdTarget at source index \(choice.index)")
            return
        }
        #expect(cardID.codingKey.stringValue == cardIDText)
        #expect(actualPurpose == purpose)
    }

    private func expectInvestigatorControl(
        _ choice: BasicChoice, expectedTag: String
    ) {
        let investigatorID: InvestigatorID
        switch (expectedTag, choice.content) {
        case let ("skip", .skipTriggers(value)):
            investigatorID = value
        case let ("start", .startSkillTest(value)):
            investigatorID = value
        default:
            Issue.record("Expected \(expectedTag) control at source index \(choice.index)")
            return
        }
        #expect(investigatorID.rawValue.rawValue == "c01001")
    }
}
