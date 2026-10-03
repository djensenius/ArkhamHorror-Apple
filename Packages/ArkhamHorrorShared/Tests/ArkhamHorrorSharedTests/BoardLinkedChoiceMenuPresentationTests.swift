@testable import ArkhamHorrorShared
import Testing

@Suite("Board linked choice menu presentation")
struct BoardLinkedChoiceMenuPresentationTests {
    @Test("Linked choice menu marks exactly the focused choice")
    func linkedChoiceMenuChoicePresentationTracksFocusedIDPerChoice() {
        let choices = [
            BoardLinkedChoice(choiceIndex: 7, title: "Fight", isActionable: true),
            BoardLinkedChoice(choiceIndex: 8, title: "Evade", isActionable: true),
        ]
        let presentations = choices.map {
            BoardLinkedChoiceMenuChoicePresentation(
                choice: $0,
                focusedID: BoardFocusID.linkedChoiceMenuChoice(8)
            )
        }

        #expect(presentations == [
            BoardLinkedChoiceMenuChoicePresentation(
                choice: choices[0],
                focusedID: BoardFocusID.linkedChoiceMenuChoice(8)
            ),
            BoardLinkedChoiceMenuChoicePresentation(
                choice: choices[1],
                focusedID: BoardFocusID.linkedChoiceMenuChoice(8)
            ),
        ])
        #expect(presentations.map(\.id) == [
            BoardFocusID.linkedChoiceMenuChoice(7),
            BoardFocusID.linkedChoiceMenuChoice(8),
        ])
        #expect(presentations.map(\.title) == ["Fight", "Evade"])
        #expect(presentations.map(\.isFocused) == [false, true])
    }
}
