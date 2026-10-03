import SwiftUI

/// Board-owned linked-choice modal used when keyboard/controller primary action lands on
/// a board element with several server choices. Keeping the choices in the board focus
/// graph avoids opening a native system menu that game controllers cannot navigate.
struct BoardLinkedChoiceMenuModalView: View {
    let request: BoardLinkedChoiceMenuRequest
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture {}
            ArkhamCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose prompt action")
                        .font(.title3.bold())
                        .foregroundStyle(ArkhamTheme.bone)
                    ForEach(request.choices, id: \.choiceIndex) { choice in
                        choiceButton(choice)
                    }
                    Text("Press Back or Secondary Action to cancel.")
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
        let id = BoardFocusID.linkedChoiceMenuChoice(choice.choiceIndex)
        return SemanticActionControl(
            accessibilityLabel: Text(choice.title),
            semanticFocusID: id,
            onOutcome: onOutcome,
            label: {
                HStack {
                    Text(choice.title)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        )
        .buttonStyle(.borderedProminent)
        .tint(ArkhamTheme.accent)
        .focused(focusBinding, equals: id)
    }
}
