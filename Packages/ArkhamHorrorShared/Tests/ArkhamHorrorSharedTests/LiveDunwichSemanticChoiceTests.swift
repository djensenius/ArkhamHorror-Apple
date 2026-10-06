@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Live Dunwich semantic choice regressions")
struct LiveDunwichSemanticChoiceTests {
    @Test("Captured Beginner's Luck opaque chaos-token labels are unpressable until localized")
    @MainActor
    func capturedBeginnersLuckOpaqueLabelsFailClosed() throws {
        let prompt = try capturedBeginnersLuckPrompt(choiceLabelResolutions: [:])
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let firstChoice = try #require(prompt.choices.first)
        let resolved = prompt.resolvedChoiceLabel(for: firstChoice, in: projection)

        #expect(firstChoice.index == 0)
        #expect(!firstChoice.isSupported)
        #expect(resolved.title == "Choice 1")
        #expect(resolved.title != "TargetLabel")
        #expect(!prompt.isChoiceActionable(firstChoice, in: projection))
        #expect(
            prompt.accessibilityHint(for: firstChoice, in: projection)
                == "The text for this choice is not currently available."
        )

        var submitted: [Int] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: prompt,
            onChoice: { submitted.append($0) }
        )
        #expect(!controller.activatePromptChoice(firstChoice.index))
        #expect(submitted.isEmpty)
    }

    @Test("Captured Beginner's Luck opaque chaos-token labels become pressable when resolved")
    @MainActor
    func capturedBeginnersLuckOpaqueLabelsUseResolvedServerText() throws {
        let prompt = try capturedBeginnersLuckPrompt(choiceLabelResolutions: [0: .resolved("+1")])
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let firstChoice = try #require(prompt.choices.first)

        #expect(prompt.displayTitle(for: firstChoice, in: projection) == "+1")
        #expect(prompt.isChoiceActionable(firstChoice, in: projection))
    }

    private func capturedBeginnersLuckPrompt(
        choiceLabelResolutions: [Int: BasicChoiceLabelResolution]
    ) throws -> BasicChoicePromptPresentation {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: fixture("c02062-beginners-luck-q11-raw-question")
        )
        let presentation = try ContractJSON.decode(
            QuestionPresentation.self,
            from: fixture("c02062-beginners-luck-q11-question-presentation")
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
            semanticLocaleIdentifier: "en",
            cardCatalog: nil,
            choiceLabelResolutions: choiceLabelResolutions,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/LiveDunwich"
            )
        )
        return try Data(contentsOf: url)
    }
}
