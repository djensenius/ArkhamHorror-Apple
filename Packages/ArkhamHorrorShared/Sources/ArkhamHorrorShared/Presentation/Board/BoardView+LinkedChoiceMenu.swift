import SwiftUI

/// Board-owned linked-choice modal used when keyboard/controller primary action lands on
/// a board element with several server choices. Keeping the choices in the board focus
/// graph avoids opening a native system menu that game controllers cannot navigate.
struct BoardLinkedChoiceMenuChoicePresentation: Sendable, Equatable {
    let id: SemanticFocusID
    let title: String
    let isFocused: Bool

    init(choice: BoardLinkedChoice, focusedID: SemanticFocusID?) {
        id = BoardFocusID.linkedChoiceMenuChoice(choice.choiceIndex)
        title = choice.title
        isFocused = focusedID == id
    }
}

struct BoardLinkedChoiceMenuModalView: View {
    let request: BoardLinkedChoiceMenuRequest
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture {}
            ArkhamCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(BoardLocalization.localized(
                        "board.linkedChoiceMenu.title",
                        "Choose prompt action"
                    ))
                    .font(.title3.bold())
                    .foregroundStyle(ArkhamTheme.bone)
                    ForEach(request.choices, id: \.choiceIndex) { choice in
                        choiceButton(choice)
                    }
                    Text(BoardLocalization.localized(
                        "board.linkedChoiceMenu.cancelHint",
                        "Press Back or Secondary Action to cancel."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 420)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func choiceButton(_ choice: BoardLinkedChoice) -> some View {
        let presentation = BoardLinkedChoiceMenuChoicePresentation(
            choice: choice,
            focusedID: focusedID
        )
        return SemanticActionControl(
            accessibilityLabel: Text(presentation.title),
            semanticFocusID: presentation.id,
            onOutcome: onOutcome,
            label: {
                HStack {
                    Text(presentation.title)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        )
        .buttonStyle(.borderedProminent)
        .tint(ArkhamTheme.accent)
        .overlay {
            if presentation.isFocused {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(ArkhamTheme.bone, lineWidth: 3)
                    .padding(-5)
                    .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)
            }
        }
        .focused(focusBinding, equals: presentation.id)
    }
}
