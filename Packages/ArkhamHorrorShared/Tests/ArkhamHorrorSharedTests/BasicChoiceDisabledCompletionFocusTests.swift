@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Basic choice disabled completion focus")
struct BasicChoiceDisabledCompletionFocusTests {
    @Test("Disabled completing choices remain visible but are not focusable actions")
    func disabledCompletingChoiceIsSkippedByFocus() throws {
        var submitted: [Int] = []
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let prompt = try incompleteChooseSome1Prompt()
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onChoice: { submitted.append($0) }
        )

        #expect(prompt.displayOrderedChoices().map(\.index) == [0, 1])
        #expect(!prompt.isChoiceActionable(prompt.displayOrderedChoices()[1], in: projection))
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(1)))
        #expect(
            controller.coordinator.graph.zoneEntryPoints[BoardFocusZone.prompt]
                == BoardFocusID.promptChoice(0)
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0])
    }

    // swiftlint:disable:next function_body_length
    private func incompleteChooseSome1Prompt() throws -> BasicChoicePromptPresentation {
        let rawQuestion = Data(
            """
            {"tag":"ChooseSome1","label":"$choose","choices":[
              {"tag":"Label","label":"$a","messages":[]},
              {"tag":"Done","label":"$done"}
            ]}
            """.utf8
        )
        let payload = try ContractJSON.decode(BasicChoiceQuestionPayload.self, from: rawQuestion)
        let presentationJSON = Data(
            """
            {
              "answer":{"kind":"singleChoice","tag":"Answer"},
              "choiceCount":2,
              "choices":[
                {
                  "kind":"localizedLabel",
                  "label":{"kind":"embeddedI18n","text":"$a"},
                  "selectable":true,
                  "sourceIndex":0
                },
                {
                  "completesSelection":true,
                  "kind":"localizedLabel",
                  "label":{"kind":"embeddedI18n","text":"$done"},
                  "selectable":true,
                  "sourceIndex":1
                }
              ],
              "protocolVersion":2,
              "questionKind":"chooseSome1",
              "questionVersion":306,
              "selection":{"max":1,"min":1}
            }
            """.utf8
        )
        let presentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: presentationJSON
        )
        let bound = try presentation.bind(
            to: payload.rawValue,
            expectedQuestionVersion: presentation.questionVersion
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: presentation.questionVersion,
                rawQuestion: payload.rawValue,
                questionPresentation: presentation,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            semanticPresentation: bound,
            choiceLabelResolutions: [
                0: .resolved("A"),
                1: .resolved("Done"),
            ],
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }
}
