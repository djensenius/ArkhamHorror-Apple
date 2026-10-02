@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves the real `question-read.json` story-continue choice remains focus-actionable and
/// directly activatable after story text falls back to server-provided keys. Split out of
/// `BasicChoiceFocusTests.swift` to keep that file under the repository's
/// `type_body_length` lint limit; shares that file's `fixture` helper via
/// `BasicChoiceFocusTests`.
extension BasicChoiceFocusTests {
    @Test(
        "The real question-read.json story-key fallback is focus-actionable and activatable"
    )
    func fallbackStoryPromptFocusesAndActivates() throws {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-read")
        )
        let story = try #require(payload.supportedQuestion?.story)
        let resolution = StoryNarrativeLocalization.resolve(
            story.flavorText,
            resolver: nil,
            catalogUnavailability: .catalog(.notAdvertised)
        )
        let fallbackPrompt = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 1,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            storyResolution: resolution,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        var submitted: [Int] = []
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let controller = BoardCommandController(
            projection: projection,
            prompt: fallbackPrompt,
            onChoice: { submitted.append($0) }
        )

        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.activatePromptChoice(0))
        #expect(submitted == [0])
    }
}
