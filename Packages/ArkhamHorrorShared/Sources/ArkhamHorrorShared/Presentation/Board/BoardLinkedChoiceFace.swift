import SwiftUI

enum BoardLinkedChoicePresentationDecision: Sendable, Equatable {
    case highlightOnly
    case submit(BoardLinkedChoice)
    case menu([BoardLinkedChoice])
}

enum BoardLinkedChoiceActivationRoute: Sendable, Equatable {
    case none
    case directChoice(BoardLinkedChoice)
    case nativeMenu([BoardLinkedChoice])
    case semanticPrimaryAction(SemanticFocusID)

    static func route(
        decision: BoardLinkedChoicePresentationDecision,
        focusID: SemanticFocusID?
    ) -> BoardLinkedChoiceActivationRoute {
        switch decision {
        case .highlightOnly:
            .none
        case let .submit(choice):
            focusID.map(Self.semanticPrimaryAction) ?? .directChoice(choice)
        case let .menu(choices):
            focusID.map(Self.semanticPrimaryAction) ?? .nativeMenu(choices)
        }
    }
}

enum BoardLinkedChoiceIndicatorTone: Sendable, Equatable {
    case idle
    case actionable
    case unavailable
}

struct BoardLinkedChoiceFaceIndicatorStyle: Sendable, Equatable {
    let tone: BoardLinkedChoiceIndicatorTone
    let innerLineWidth: CGFloat
    let showsFocusedOuterRing: Bool

    static func style(
        linkedChoices: [BoardLinkedChoice],
        isFocused: Bool
    ) -> BoardLinkedChoiceFaceIndicatorStyle {
        let tone: BoardLinkedChoiceIndicatorTone = if linkedChoices.isEmpty {
            .idle
        } else if linkedChoices.contains(where: \.isActionable) {
            .actionable
        } else {
            .unavailable
        }
        return BoardLinkedChoiceFaceIndicatorStyle(
            tone: tone,
            innerLineWidth: isFocused || !linkedChoices.isEmpty ? 3 : 1,
            showsFocusedOuterRing: isFocused
        )
    }
}

enum BoardLinkedChoicePresentationPolicy {
    static func decision(
        for linkedChoices: [BoardLinkedChoice]
    ) -> BoardLinkedChoicePresentationDecision {
        let actionableChoices = linkedChoices.filter(\.isActionable)
        switch actionableChoices.count {
        case 0:
            return .highlightOnly
        case 1:
            return .submit(actionableChoices[0])
        default:
            return .menu(actionableChoices)
        }
    }
}

/// Native touch/pointer/VoiceOver board affordance, with an optional semantic focus ID
/// for linked elements that can answer the current server prompt from the board itself.
struct BoardLinkedChoiceFace<Content: View>: View {
    let accessibilityLabel: String
    let linkedChoices: [BoardLinkedChoice]
    let focusID: SemanticFocusID?
    let isFocused: Bool
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onLinkedChoice: (Int) -> Void
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        let decision = BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices)
        switch BoardLinkedChoiceActivationRoute.route(decision: decision, focusID: focusID) {
        case .none:
            content()
                .cardFaceStyle(linkedChoices: linkedChoices, isFocused: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityLabel))
        case let .directChoice(choice):
            Button { onLinkedChoice(choice.choiceIndex) } label: {
                content().cardFaceStyle(linkedChoices: linkedChoices, isFocused: isFocused)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityHint(activationHint(choice.title))
            .linkedChoiceFocused(focusID, focusBinding: focusBinding)
        case let .nativeMenu(actionableChoices):
            Menu {
                ForEach(actionableChoices, id: \.choiceIndex) { choice in
                    Button(choice.title) { onLinkedChoice(choice.choiceIndex) }
                }
            } label: {
                content().cardFaceStyle(linkedChoices: linkedChoices, isFocused: isFocused)
            }
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityHint(choiceMenuHint)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .linkedChoiceFocused(focusID, focusBinding: focusBinding)
        case let .semanticPrimaryAction(focusID):
            SemanticActionControl(
                accessibilityLabel: Text(accessibilityLabel),
                semanticFocusID: focusID,
                onOutcome: onOutcome,
                label: {
                    content().cardFaceStyle(linkedChoices: linkedChoices, isFocused: isFocused)
                }
            )
            .buttonStyle(.plain)
            .accessibilityHint(semanticHint(for: decision))
            .focused(focusBinding, equals: focusID)
        }
    }

    private func semanticHint(for decision: BoardLinkedChoicePresentationDecision) -> Text {
        switch decision {
        case let .submit(choice):
            activationHint(choice.title)
        case .menu:
            choiceMenuHint
        case .highlightOnly:
            Text("")
        }
    }

    private func activationHint(_ title: String) -> Text {
        Text(BoardLocalization.format(
            "board.linkedChoice.activateHint",
            "Activates %@",
            title
        ))
    }

    private var choiceMenuHint: Text {
        Text(BoardLocalization.localized(
            "board.linkedChoice.chooseHint",
            "Choose which prompt action to take."
        ))
    }
}

private extension View {
    func cardFaceStyle(linkedChoices: [BoardLinkedChoice], isFocused: Bool) -> some View {
        let indicator = BoardLinkedChoiceFaceIndicatorStyle.style(
            linkedChoices: linkedChoices,
            isFocused: isFocused
        )
        return padding(8)
            .frame(width: 116, alignment: .leading)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(indicator.strokeColor, lineWidth: indicator.innerLineWidth)
            }
            .overlay {
                if indicator.showsFocusedOuterRing {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(ArkhamTheme.bone, lineWidth: 2)
                        .padding(-4)
                        .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)
                }
            }
    }

    @ViewBuilder
    func linkedChoiceFocused(
        _ focusID: SemanticFocusID?,
        focusBinding: FocusState<SemanticFocusID?>.Binding
    ) -> some View {
        if let focusID {
            focused(focusBinding, equals: focusID)
        } else {
            self
        }
    }
}

private extension BoardLinkedChoiceFaceIndicatorStyle {
    var strokeColor: Color {
        switch tone {
        case .idle:
            .white.opacity(0.12)
        case .actionable:
            ArkhamTheme.accent
        case .unavailable:
            .orange.opacity(0.45)
        }
    }
}
