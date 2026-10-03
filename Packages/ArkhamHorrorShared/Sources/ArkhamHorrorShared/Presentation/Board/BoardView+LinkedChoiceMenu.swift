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

enum BoardLinkedChoiceMenuLayout {
    static let minimumChoiceListHeight: CGFloat = 120
    private static let maximumChoiceListHeight: CGFloat = 360
    private static let reservedVerticalChrome: CGFloat = 180

    static func choiceListHeight(containerHeight: CGFloat) -> CGFloat {
        min(
            max(containerHeight - reservedVerticalChrome, minimumChoiceListHeight),
            maximumChoiceListHeight
        )
    }
}

struct BoardLinkedChoiceMenuCancelDispatch: Sendable, Equatable {
    let focusID: SemanticFocusID
    let outcome: SemanticDispatchOutcome
}

enum BoardLinkedChoiceMenuCancelAction {
    static func dispatch(for request: BoardLinkedChoiceMenuRequest) -> BoardLinkedChoiceMenuCancelDispatch {
        BoardLinkedChoiceMenuCancelDispatch(focusID: request.focusID, outcome: .reservedBack)
    }
}

enum BoardLinkedChoiceMenuScrollTarget {
    static func focusedChoiceID(
        choices: [BoardLinkedChoice],
        focusedID: SemanticFocusID?
    ) -> SemanticFocusID? {
        guard let focusedID,
              choices.contains(where: {
                  BoardFocusID.linkedChoiceMenuChoice($0.choiceIndex) == focusedID
              })
        else { return nil }
        return focusedID
    }
}

struct BoardLinkedChoiceMenuModalView: View {
    let request: BoardLinkedChoiceMenuRequest
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.45)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                ArkhamCard {
                    modalContent(choiceListHeight: BoardLinkedChoiceMenuLayout.choiceListHeight(
                        containerHeight: proxy.size.height
                    ))
                }
                .frame(maxWidth: 420)
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, cancel)
        }
    }

    private func cancel() {
        let dispatch = BoardLinkedChoiceMenuCancelAction.dispatch(for: request)
        onOutcome(dispatch.focusID, dispatch.outcome)
    }

    private func modalContent(choiceListHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(BoardLocalization.localized(
                "board.linkedChoiceMenu.title",
                "Choose prompt action"
            ))
            .font(.title3.bold())
            .foregroundStyle(ArkhamTheme.bone)
            choiceList(maxHeight: choiceListHeight)
            Text(BoardLocalization.localized(
                "board.linkedChoiceMenu.cancelHint",
                "Press Back or Secondary Action to cancel."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func choiceList(maxHeight: CGFloat) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(request.choices, id: \.choiceIndex) { choice in
                        choiceButton(choice)
                            .id(BoardFocusID.linkedChoiceMenuChoice(choice.choiceIndex))
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: maxHeight)
            .onAppear { scrollFocusedChoice(with: scrollProxy) }
            .onChange(of: focusedID) { _, _ in
                scrollFocusedChoice(with: scrollProxy)
            }
        }
    }

    private func scrollFocusedChoice(with proxy: ScrollViewProxy) {
        guard let target = BoardLinkedChoiceMenuScrollTarget.focusedChoiceID(
            choices: request.choices,
            focusedID: focusedID
        ) else { return }
        withAnimation {
            proxy.scrollTo(target, anchor: .center)
        }
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
