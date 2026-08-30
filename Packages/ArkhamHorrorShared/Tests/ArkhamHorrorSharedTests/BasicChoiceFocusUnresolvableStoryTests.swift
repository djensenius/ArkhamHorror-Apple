@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves the real, unresolvable `question-read.json` story-continue choice (issue
/// djensenius/ArkhamHorror-Apple#35, independent-review blocker 2) is never
/// focus-actionable or directly activatable through ``BoardCommandController`` -- it
/// remains visible/disabled rather than silently behaving as though it were an actionable
/// Continue. Split out of `BasicChoiceFocusTests.swift` to keep that file under the
/// repository's `type_body_length` lint limit; shares that file's `fixture` helper via
/// `BasicChoiceFocusTests`.
extension BasicChoiceFocusTests {
    @Test(
        "The real, unresolvable question-read.json story is never focus-actionable or activatable"
    )
    func unresolvableStoryPromptNeverFocusesOrActivates() throws {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: fixture("question-read")
        )
        let unresolvablePrompt = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 1,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        var submitted: [Int] = []
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let controller = try BoardCommandController(
            projection: projection,
            prompt: unresolvablePrompt,
            onChoice: { submitted.append($0) }
        )

        // No candidate is actionable, so jumping to the prompt finds nothing to focus.
        #expect(!controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus != BoardFocusID.promptChoice(0))
        // Direct activation of the disabled choice is likewise rejected -- it remains
        // visible/disabled, never silently treated as an actionable Continue.
        #expect(!controller.activatePromptChoice(0))
        #expect(submitted.isEmpty)
    }
}
