import SwiftUI

enum BoardLinkedChoicePresentationDecision: Sendable, Equatable {
    case highlightOnly
    case submit(BoardLinkedChoice)
    case menu([BoardLinkedChoice])
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
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
        case .highlightOnly:
            content()
                .cardFaceStyle(linkedChoices: linkedChoices, isFocused: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityLabel))
        case let .submit(choice):
            Button { onLinkedChoice(choice.choiceIndex) } label: {
                content().cardFaceStyle(linkedChoices: linkedChoices, isFocused: isFocused)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityHint(Text("Activates \(choice.title)"))
            .linkedChoiceFocused(focusID, focusBinding: focusBinding)
        case let .menu(actionableChoices):
            Menu {
                ForEach(actionableChoices, id: \.choiceIndex) { choice in
                    Button(choice.title) { onLinkedChoice(choice.choiceIndex) }
                }
            } label: {
                content().cardFaceStyle(linkedChoices: linkedChoices, isFocused: isFocused)
            }
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityHint(Text("Choose which prompt action to take."))
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .linkedChoiceFocused(focusID, focusBinding: focusBinding)
        }
    }
}

private extension View {
    func cardFaceStyle(linkedChoices: [BoardLinkedChoice], isFocused: Bool) -> some View {
        padding(8)
            .frame(width: 116, alignment: .leading)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        outlineColor(linkedChoices, isFocused: isFocused),
                        lineWidth: isFocused || !linkedChoices.isEmpty ? 3 : 1
                    )
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

    private func outlineColor(_ linkedChoices: [BoardLinkedChoice], isFocused: Bool) -> Color {
        if isFocused {
            return ArkhamTheme.accent
        }
        guard !linkedChoices.isEmpty else { return .white.opacity(0.12) }
        let hasActionable = linkedChoices.contains(where: \.isActionable)
        return hasActionable ? ArkhamTheme.accent : .orange.opacity(0.45)
    }
}
