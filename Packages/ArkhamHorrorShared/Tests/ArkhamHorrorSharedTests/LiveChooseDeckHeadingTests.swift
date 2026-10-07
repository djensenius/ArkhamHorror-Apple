@testable import ArkhamHorrorShared
import Testing

@Suite("Live ChooseDeck headings")
struct LiveChooseDeckHeadingTests {
    private func liveChooseDeckPrompt(
        questionLabelText: String
    ) throws -> BasicChoicePromptPresentation {
        let rawQuestion = JSONValue.object([
            "card": .null,
            "label": .string(questionLabelText),
            "question": .object(["tag": .string("ChooseDeck")]),
            "tag": .string("QuestionLabel"),
        ])
        let presentation = QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: 10,
            questionKind: .chooseDeck,
            choiceCount: 0,
            choices: [],
            answer: .deck(tags: ["DeckAnswer"]),
            questionLabel: .init(kind: .embeddedI18n, text: questionLabelText)
        )
        let binding = try presentation.bind(to: rawQuestion, expectedQuestionVersion: 10)
        let ownerID = BoardTestFixtures.playerID()
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: ownerID,
                questionVersion: 10,
                rawQuestion: rawQuestion,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: .updateRequired(tag: "ChooseDeck"),
            semanticPresentation: binding,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    @Test("Live deck picker heading uses a literal QuestionLabel")
    func liveDeckPickerHeadingUsesLiteralQuestionLabel() throws {
        let prompt = try liveChooseDeckPrompt(questionLabelText: "  Choose Dream Side  ")

        #expect(prompt.promptLabelResolutions["questionLabel"] == nil)
        #expect(prompt.liveChooseDeckPickerHeading == "Choose Dream Side")
        #expect(!prompt.liveChooseDeckPickerHeading.contains("$"))
    }

    @Test("Live deck picker heading falls back for an empty literal QuestionLabel")
    func liveDeckPickerHeadingFallsBackForEmptyLiteralQuestionLabel() throws {
        let prompt = try liveChooseDeckPrompt(questionLabelText: " \n\t ")

        #expect(
            prompt.liveChooseDeckPickerHeading ==
                BasicChoicePromptPresentation.liveChooseDeckGenericHeading()
        )
    }
}
