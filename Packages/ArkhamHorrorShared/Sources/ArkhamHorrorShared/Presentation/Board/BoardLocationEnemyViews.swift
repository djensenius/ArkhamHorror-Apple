import SwiftUI

struct BoardLocationEnemyTileMetrics: Sendable, Equatable {
    let headerReservedHeight: CGFloat
    let chipRowHeight: CGFloat
    let summaryButtonHeight: CGFloat
    let chipMinWidth: CGFloat
    let moreButtonMinWidth: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    static let regular = BoardLocationEnemyTileMetrics(
        headerReservedHeight: 64,
        chipRowHeight: 24,
        summaryButtonHeight: 18,
        chipMinWidth: 70,
        moreButtonMinWidth: 48,
        horizontalSpacing: 4,
        verticalSpacing: 6
    )
    static let tvOS = BoardLocationEnemyTileMetrics(
        headerReservedHeight: 76,
        chipRowHeight: 32,
        summaryButtonHeight: 22,
        chipMinWidth: 86,
        moreButtonMinWidth: 64,
        horizontalSpacing: 6,
        verticalSpacing: 6
    )

    static var current: BoardLocationEnemyTileMetrics {
        #if os(tvOS)
            tvOS
        #else
            regular
        #endif
    }
}

enum BoardLocationEnemyTileLayoutDecision: Sendable, Equatable {
    case hidden
    case summaryButton
    case chips(visibleCount: Int, hasMore: Bool)
}

enum BoardLocationEnemyTileLayout {
    static func decision(
        enemyCount: Int,
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        metrics: BoardLocationEnemyTileMetrics
    ) -> BoardLocationEnemyTileLayoutDecision {
        guard enemyCount > 0,
              availableHeight >= metrics.summaryButtonHeight,
              availableWidth >= metrics.moreButtonMinWidth
        else { return .hidden }
        guard availableHeight >= metrics.chipRowHeight,
              availableWidth >= metrics.chipMinWidth
        else { return .summaryButton }
        let slotsWithoutOverflow = chipSlots(
            availableWidth: availableWidth,
            metrics: metrics
        )
        guard slotsWithoutOverflow > 0 else { return .summaryButton }
        if enemyCount <= slotsWithoutOverflow {
            return .chips(visibleCount: enemyCount, hasMore: false)
        }
        let overflowWidth = metrics.moreButtonMinWidth + metrics.horizontalSpacing
        let slotsWithOverflow = chipSlots(
            availableWidth: availableWidth - overflowWidth,
            metrics: metrics
        )
        guard slotsWithOverflow > 0 else { return .summaryButton }
        return .chips(visibleCount: min(enemyCount, slotsWithOverflow), hasMore: true)
    }

    private static func chipSlots(
        availableWidth: CGFloat,
        metrics: BoardLocationEnemyTileMetrics
    ) -> Int {
        guard availableWidth >= metrics.chipMinWidth else { return 0 }
        let slotWidth = metrics.chipMinWidth + metrics.horizontalSpacing
        return max(Int((availableWidth + metrics.horizontalSpacing) / slotWidth), 0)
    }
}

struct BoardEnemyCompactPanelView: View {
    let title: String
    let enemies: [BoardEnemyNode]
    let visibleCount: Int
    let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            ForEach(Array(enemies.prefix(visibleCount))) { enemy in
                BoardEnemyCompactChipView(
                    enemy: enemy,
                    linkedChoices: choiceLinks[.enemy(enemy.id)] ?? [],
                    onLinkedChoice: onLinkedChoice
                )
            }
            if enemies.count > visibleCount {
                BoardEnemyOverflowMenu(
                    label: "+\(enemies.count - visibleCount) more enemies",
                    enemies: enemies,
                    choiceLinks: choiceLinks,
                    onLinkedChoice: onLinkedChoice
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

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
            chip
        case let .submit(choice):
            Button { onLinkedChoice(choice.choiceIndex) } label: { chip }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Activates \(choice.title)"))
        case let .menu(actionableChoices):
            Menu {
                ForEach(actionableChoices, id: \.choiceIndex) { choice in
                    Button(choice.title) { onLinkedChoice(choice.choiceIndex) }
                }
            } label: {
                chip
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityHint(Text("Choose which prompt action to take."))
        }
    }

    private var chip: some View {
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
                .strokeBorder(outlineColor, lineWidth: linkedChoices.isEmpty ? 1 : 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(BoardAccessibility.summary(
            enemy: enemy,
            displayName: displayName
        )))
    }

    private var outlineColor: Color {
        guard !linkedChoices.isEmpty else { return .white.opacity(0.12) }
        return linkedChoices.contains(where: \.isActionable)
            ? ArkhamTheme.accent
            : .orange.opacity(0.45)
    }
}

struct BoardEnemyOverflowMenu: View {
    let label: String
    let enemies: [BoardEnemyNode]
    let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    let onLinkedChoice: (Int) -> Void
    @Environment(\.boardCardCatalog) private var cardCatalog

    var body: some View {
        Menu {
            ForEach(enemies) { enemy in
                let linkedChoices = choiceLinks[.enemy(enemy.id)] ?? []
                switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
                case .highlightOnly:
                    Text(menuSummary(enemy, linkedChoices: linkedChoices))
                case let .submit(choice):
                    Button("\(menuSummary(enemy, linkedChoices: linkedChoices)): \(choice.title)") {
                        onLinkedChoice(choice.choiceIndex)
                    }
                case let .menu(actionableChoices):
                    Menu(menuSummary(enemy, linkedChoices: linkedChoices)) {
                        ForEach(actionableChoices, id: \.choiceIndex) { choice in
                            Button(choice.title) { onLinkedChoice(choice.choiceIndex) }
                        }
                    }
                }
            }
        } label: {
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(ArkhamTheme.accent)
        }
        .accessibilityLabel(Text("Show all \(enemies.count) enemies"))
    }

    private func menuSummary(
        _ enemy: BoardEnemyNode,
        linkedChoices: [BoardLinkedChoice]
    ) -> String {
        let displayName = enemy.cardCode.flatMap { cardCatalog?.displayName(for: $0) }
            ?? enemy.displayName
        let summary = BoardEnemyCompactFormatting.listSummary(enemy, displayName: displayName)
        guard !linkedChoices.isEmpty else { return summary }
        return linkedChoices.contains(where: \.isActionable)
            ? "\(summary) — prompt action"
            : "\(summary) — prompt unavailable"
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
            chip
        case let .submit(choice):
            Button { onLinkedChoice(choice.choiceIndex) } label: { chip }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Activates \(choice.title)"))
        case let .menu(actionableChoices):
            Menu {
                ForEach(actionableChoices, id: \.choiceIndex) { choice in
                    Button(choice.title) { onLinkedChoice(choice.choiceIndex) }
                }
            } label: {
                chip
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityHint(Text("Choose which prompt action to take."))
        }
    }

    private var chip: some View {
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
                .strokeBorder(outlineColor, lineWidth: linkedChoices.isEmpty ? 1 : 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(BoardAccessibility.summary(
            enemy: enemy,
            displayName: displayName
        )))
    }

    private var outlineColor: Color {
        guard !linkedChoices.isEmpty else { return .white.opacity(0.12) }
        return actionableChoices.isEmpty ? .orange.opacity(0.45) : ArkhamTheme.accent
    }
}

private enum BoardEnemyCompactFormatting {
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
