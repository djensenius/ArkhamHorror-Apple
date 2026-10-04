@testable import ArkhamHorrorShared
import Testing

@Suite("Board linked choice faces")
struct BoardLinkedChoiceFaceTests {
    @Test("Focused linked faces add an outer ring distinct from actionable highlight")
    func focusedLinkedFacesAddDistinctOuterRing() {
        let choices = [BoardLinkedChoice(choiceIndex: 7, title: "Fight", isActionable: true)]

        let focusedStyle = BoardLinkedChoiceFaceIndicatorStyle.style(
            linkedChoices: choices,
            isFocused: true
        )
        let unfocusedStyle = BoardLinkedChoiceFaceIndicatorStyle.style(
            linkedChoices: choices,
            isFocused: false
        )

        #expect(focusedStyle.tone == .actionable)
        #expect(unfocusedStyle.tone == .actionable)
        #expect(focusedStyle.innerLineWidth == unfocusedStyle.innerLineWidth)
        #expect(focusedStyle.showsFocusedOuterRing)
        #expect(!unfocusedStyle.showsFocusedOuterRing)
    }

    @Test("Focusable multi-choice linked faces route native activation through primary action")
    func focusableMultiChoiceLinkedFaceRoutesActivationThroughPrimaryAction() {
        let focusID = BoardFocusID.promptElement(.enemy(BoardTestFixtures.enemyID("000000000438")))
        let choices = [
            BoardLinkedChoice(choiceIndex: 7, title: "Fight", isActionable: true),
            BoardLinkedChoice(choiceIndex: 8, title: "Evade", isActionable: true),
        ]
        let decision = BoardLinkedChoicePresentationPolicy.decision(for: choices)

        #expect(BoardLinkedChoiceActivationRoute.route(
            decision: decision,
            focusID: focusID
        ) == .semanticPrimaryAction(focusID))
        #expect(BoardLinkedChoiceActivationRoute.route(
            decision: decision,
            focusID: nil
        ) == .nativeMenu(choices))
    }
}
