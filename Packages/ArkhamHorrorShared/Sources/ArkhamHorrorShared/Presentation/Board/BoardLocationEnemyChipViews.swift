import SwiftUI

struct BoardEnemyTileChipView: View {
    let enemy: BoardEnemyNode
    let linkedChoices: [BoardLinkedChoice]
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onLinkedChoice: (Int) -> Void
    @Environment(\.boardCardCatalog) private var cardCatalog

    private var displayName: String {
        enemy.cardCode.flatMap { cardCatalog?.displayName(for: $0) } ?? enemy.displayName
    }

    private var linkedFocusID: SemanticFocusID? {
        switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
        case .submit, .menu: BoardFocusID.promptElement(.enemy(enemy.id))
        case .highlightOnly: nil
        }
    }

    var body: some View {
        switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
        case .highlightOnly:
            chip(isFocused: false)
        case let .submit(choice):
            Button { onLinkedChoice(choice.choiceIndex) } label: { chip(isFocused: isFocused) }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Activates \(choice.title)"))
                .linkedChoiceFocused(linkedFocusID, focusBinding: focusBinding)
        case let .menu(actionableChoices):
            Menu {
                ForEach(actionableChoices, id: \.choiceIndex) { choice in
                    Button(choice.title) { onLinkedChoice(choice.choiceIndex) }
                }
            } label: {
                chip(isFocused: isFocused)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityHint(Text("Choose which prompt action to take."))
            .linkedChoiceFocused(linkedFocusID, focusBinding: focusBinding)
        }
    }

    private var isFocused: Bool {
        focusedID == linkedFocusID
    }

    private func chip(isFocused: Bool) -> some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.caption2.bold())
                    .lineLimit(1)
                    .foregroundStyle(ArkhamTheme.bone)
                Text(BoardEnemyCompactFormatting.statsSummary(enemy))
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Text(displayName)
                .font(.caption2.bold())
                .lineLimit(1)
                .foregroundStyle(ArkhamTheme.bone)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(
            width: BoardLocationEnemyTileMetrics.current.chipMinWidth,
            height: BoardLocationEnemyTileMetrics.current.chipRowHeight,
            alignment: .leading
        )
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(outlineColor(isFocused: isFocused), lineWidth: lineWidth(isFocused))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(BoardAccessibility.summary(
            enemy: enemy,
            displayName: displayName
        )))
    }

    private func lineWidth(_ isFocused: Bool) -> CGFloat {
        isFocused ? 3 : (linkedChoices.isEmpty ? 1 : 2)
    }

    private func outlineColor(isFocused: Bool) -> Color {
        if isFocused {
            return ArkhamTheme.accent
        }
        guard !linkedChoices.isEmpty else { return .white.opacity(0.12) }
        return linkedChoices.contains(where: \.isActionable)
            ? ArkhamTheme.accent
            : .orange.opacity(0.45)
    }
}

struct BoardEnemyCompactChipView: View {
    let enemy: BoardEnemyNode
    let linkedChoices: [BoardLinkedChoice]
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onLinkedChoice: (Int) -> Void
    @Environment(\.boardCardCatalog) private var cardCatalog

    private var displayName: String {
        enemy.cardCode.flatMap { cardCatalog?.displayName(for: $0) } ?? enemy.displayName
    }

    private var actionableChoices: [BoardLinkedChoice] {
        linkedChoices.filter(\.isActionable)
    }

    private var linkedFocusID: SemanticFocusID? {
        switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
        case .submit, .menu: BoardFocusID.promptElement(.enemy(enemy.id))
        case .highlightOnly: nil
        }
    }

    var body: some View {
        switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
        case .highlightOnly:
            chip(isFocused: false)
        case let .submit(choice):
            Button { onLinkedChoice(choice.choiceIndex) } label: { chip(isFocused: isFocused) }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Activates \(choice.title)"))
                .linkedChoiceFocused(linkedFocusID, focusBinding: focusBinding)
        case let .menu(actionableChoices):
            Menu {
                ForEach(actionableChoices, id: \.choiceIndex) { choice in
                    Button(choice.title) { onLinkedChoice(choice.choiceIndex) }
                }
            } label: {
                chip(isFocused: isFocused)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityHint(Text("Choose which prompt action to take."))
            .linkedChoiceFocused(linkedFocusID, focusBinding: focusBinding)
        }
    }

    private var isFocused: Bool {
        focusedID == linkedFocusID
    }

    private func chip(isFocused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayName)
                .font(.caption2.bold())
                .lineLimit(1)
                .foregroundStyle(ArkhamTheme.bone)
            Text(BoardEnemyCompactFormatting.statsSummary(enemy))
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(outlineColor(isFocused: isFocused), lineWidth: lineWidth(isFocused))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(BoardAccessibility.summary(
            enemy: enemy,
            displayName: displayName
        )))
    }

    private func lineWidth(_ isFocused: Bool) -> CGFloat {
        isFocused ? 3 : (linkedChoices.isEmpty ? 1 : 2)
    }

    private func outlineColor(isFocused: Bool) -> Color {
        if isFocused {
            return ArkhamTheme.accent
        }
        guard !linkedChoices.isEmpty else { return .white.opacity(0.12) }
        return actionableChoices.isEmpty ? .orange.opacity(0.45) : ArkhamTheme.accent
    }
}

private extension View {
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

enum BoardEnemyCompactFormatting {
    static func statsSummary(_ enemy: BoardEnemyNode) -> String {
        var parts: [String] = []
        if let fight = enemy.fight {
            parts.append("F \(fight.displayValue)")
        }
        if let health = enemy.health {
            parts.append("H \(health.displayValue)")
        }
        if let evade = enemy.evade {
            parts.append("E \(evade.displayValue)")
        }
        if let damage = enemy.damage, damage > 0 {
            parts.append("Dmg \(damage)")
        }
        return parts.isEmpty ? "Enemy" : parts.joined(separator: "  ")
    }

    static func listSummary(_ enemy: BoardEnemyNode, displayName: String) -> String {
        "\(displayName): \(statsSummary(enemy))"
    }
}
