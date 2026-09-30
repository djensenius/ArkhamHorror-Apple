import SwiftUI

/// Native touch/pointer/VoiceOver board affordance. Keyboard/controller semantic focus for
/// these linked elements is deliberately deferred to the board-element focus follow-up lane;
/// the prompt panel remains the keyboard/controller answer surface in this PR.
struct BoardLinkedChoiceFace<Content: View>: View {
    let accessibilityLabel: String
    let linkedChoices: [BoardLinkedChoice]
    let onLinkedChoice: (Int) -> Void
    @ViewBuilder let content: () -> Content

    private var actionableChoices: [BoardLinkedChoice] {
        linkedChoices.filter(\.isActionable)
    }

    var body: some View {
        switch actionableChoices.count {
        case 0:
            content()
                .cardFaceStyle(linkedChoices: linkedChoices)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityLabel))
        case 1:
            if let choice = actionableChoices.first {
                Button { onLinkedChoice(choice.choiceIndex) } label: {
                    content().cardFaceStyle(linkedChoices: linkedChoices)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityHint(Text("Activates \(choice.title)"))
            }
        default:
            Menu {
                ForEach(actionableChoices, id: \.choiceIndex) { choice in
                    Button(choice.title) { onLinkedChoice(choice.choiceIndex) }
                }
            } label: {
                content().cardFaceStyle(linkedChoices: linkedChoices)
            }
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityHint(Text("Choose which prompt action to take."))
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }
}

private extension View {
    func cardFaceStyle(linkedChoices: [BoardLinkedChoice]) -> some View {
        padding(8)
            .frame(width: 116, alignment: .leading)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        outlineColor(linkedChoices),
                        lineWidth: linkedChoices.isEmpty ? 1 : 3
                    )
            }
    }

    private func outlineColor(_ linkedChoices: [BoardLinkedChoice]) -> Color {
        guard !linkedChoices.isEmpty else { return .white.opacity(0.12) }
        let hasActionable = linkedChoices.contains(where: \.isActionable)
        return hasActionable ? ArkhamTheme.accent : .orange.opacity(0.45)
    }
}
