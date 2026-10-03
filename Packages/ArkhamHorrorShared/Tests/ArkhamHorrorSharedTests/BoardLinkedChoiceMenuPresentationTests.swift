@testable import ArkhamHorrorShared
import Testing

@Suite("Board linked choice menu presentation")
struct BoardLinkedChoiceMenuPresentationTests {
    @Test("Linked choice menu list height stays within available modal height")
    func linkedChoiceMenuListHeightStaysWithinAvailableModalHeight() {
        #expect(BoardLinkedChoiceMenuLayout.choiceListHeight(containerHeight: 220) == 120)
        #expect(BoardLinkedChoiceMenuLayout.choiceListHeight(containerHeight: 420) == 240)
        #expect(BoardLinkedChoiceMenuLayout.choiceListHeight(containerHeight: 900) == 360)
    }

    @Test("Linked choice menu scroll target follows the focused choice")
    func linkedChoiceMenuScrollTargetFollowsFocusedChoice() {
        let choices = [
            BoardLinkedChoice(choiceIndex: 7, title: "Fight", isActionable: true),
            BoardLinkedChoice(choiceIndex: 8, title: "Evade", isActionable: true),
        ]

        #expect(BoardLinkedChoiceMenuScrollTarget.focusedChoiceID(
            choices: choices,
            focusedID: BoardFocusID.linkedChoiceMenuChoice(8)
        ) == BoardFocusID.linkedChoiceMenuChoice(8))
        #expect(BoardLinkedChoiceMenuScrollTarget.focusedChoiceID(
            choices: choices,
            focusedID: BoardFocusID.linkedChoiceMenuChoice(99)
        ) == nil)
    }

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
