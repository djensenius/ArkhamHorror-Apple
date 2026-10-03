import SwiftUI

struct BoardEnemyTileChipView: View {
    let enemy: BoardEnemyNode
    let linkedChoices: [BoardLinkedChoice]
    let onLinkedChoice: (Int) -> Void
    @Environment(\.boardCardCatalog) private var cardCatalog

    private var displayName: String {
        enemy.cardCode.flatMap { cardCatalog?.displayName(for: $0) } ?? enemy.displayName
    }

    var body: some View {
        switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
        case .highlightOnly:
            chip(isFocused: false)
        case let .submit(choice):
            Button { onLinkedChoice(choice.choiceIndex) } label: { chip(isFocused: false) }
                .buttonStyle(.plain)
                .accessibilityHint(Text(BoardLocalization.format(
                    "board.linkedChoice.activateHint",
                    "Activates %@",
                    choice.title
                )))
        case let .menu(actionableChoices):
            Menu {
                ForEach(actionableChoices, id: \.choiceIndex) { choice in
                    Button(choice.title) { onLinkedChoice(choice.choiceIndex) }
                }
            } label: {
                chip(isFocused: false)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityHint(Text(BoardLocalization.localized(
                "board.linkedChoice.chooseHint",
                "Choose which prompt action to take."
            )))
        }
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
    let onLinkedChoice: (Int) -> Void
    @Environment(\.boardCardCatalog) private var cardCatalog

    private var displayName: String {
        enemy.cardCode.flatMap { cardCatalog?.displayName(for: $0) } ?? enemy.displayName
    }

    private var actionableChoices: [BoardLinkedChoice] {
        linkedChoices.filter(\.isActionable)
    }

    var body: some View {
        switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
        case .highlightOnly:
            chip(isFocused: false)
        case let .submit(choice):
            Button { onLinkedChoice(choice.choiceIndex) } label: { chip(isFocused: false) }
                .buttonStyle(.plain)
                .accessibilityHint(Text(BoardLocalization.format(
                    "board.linkedChoice.activateHint",
                    "Activates %@",
                    choice.title
                )))
        case let .menu(actionableChoices):
            Menu {
                ForEach(actionableChoices, id: \.choiceIndex) { choice in
                    Button(choice.title) { onLinkedChoice(choice.choiceIndex) }
                }
            } label: {
                chip(isFocused: false)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityHint(Text(BoardLocalization.localized(
                "board.linkedChoice.chooseHint",
                "Choose which prompt action to take."
            )))
        }
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

enum BoardEnemyCompactFormatting {
    static func titledLinkedChoicesByEnemy(
        enemies: [BoardEnemyNode],
        choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]],
        cardCatalog: CardCatalogSnapshot? = nil
    ) -> [BoardLinkedChoice] {
        let summaries = enemies.map { enemy in
            listSummary(enemy, displayName: displayName(for: enemy, cardCatalog: cardCatalog))
        }
        let duplicateCounts = Dictionary(summaries.map { ($0, 1) }, uniquingKeysWith: +)
        var seenCounts: [String: Int] = [:]
        return zip(enemies, summaries).flatMap { enemy, summary in
            let seen = (seenCounts[summary] ?? 0) + 1
            seenCounts[summary] = seen
            let disambiguatedSummary = duplicateCounts[summary, default: 0] > 1
                ? duplicateEnemySummary(summary, ordinal: seen)
                : summary
            return (choiceLinks[.enemy(enemy.id)] ?? []).map { choice in
                BoardLinkedChoice(
                    choiceIndex: choice.choiceIndex,
                    title: "\(disambiguatedSummary): \(choice.title)",
                    isActionable: choice.isActionable
                )
            }
        }
    }

    private static func displayName(
        for enemy: BoardEnemyNode,
        cardCatalog: CardCatalogSnapshot?
    ) -> String {
        enemy.cardCode.flatMap { cardCatalog?.displayName(for: $0) } ?? enemy.displayName
    }

    private static func duplicateEnemySummary(_ summary: String, ordinal: Int) -> String {
        BoardLocalization.format(
            "board.enemyActions.duplicateSuffix",
            "%1$@ (enemy %2$lld)",
            summary,
            ordinal
        )
    }

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
