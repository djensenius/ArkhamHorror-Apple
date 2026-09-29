import SwiftUI

extension EnvironmentValues {
    @Entry var boardCardCatalog: CardCatalogSnapshot?
}

struct BoardPlayerAreaView: View {
    let investigator: BoardInvestigatorNode
    let handCards: [BoardPlayerCardNode]
    let inPlayCards: [BoardPlayerCardNode]
    let threatTreacheries: [BoardThreatTreacheryNode]
    let engagedEnemies: [BoardEnemyNode]
    let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !handCards.isEmpty {
                cardStrip(title: "Hand", cards: handCards)
            }
            if !inPlayCards.isEmpty {
                cardStrip(title: "Play area", cards: inPlayCards)
            }
            if !engagedEnemies.isEmpty {
                BoardEnemyPanelView(
                    title: "Engaged", enemies: engagedEnemies,
                    choiceLinks: choiceLinks, onLinkedChoice: onLinkedChoice
                )
            }
            if !threatTreacheries.isEmpty {
                BoardThreatAreaView(
                    treacheries: threatTreacheries,
                    choiceLinks: choiceLinks,
                    onLinkedChoice: onLinkedChoice
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(investigator.displayName) player area")
    }

    private func cardStrip(title: String, cards: [BoardPlayerCardNode]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(cards) { card in
                        BoardPlayerCardFaceView(
                            card: card,
                            linkedChoices: choiceLinks[.playerCard(card.id)] ?? [],
                            onLinkedChoice: onLinkedChoice
                        )
                    }
                }
            }
        }
    }
}

struct BoardPlayerCardFaceView: View {
    let card: BoardPlayerCardNode
    let linkedChoices: [BoardLinkedChoice]
    let onLinkedChoice: (Int) -> Void
    @Environment(\.boardCardCatalog) private var cardCatalog

    private var displayName: String {
        card.cardCode.flatMap { cardCatalog?.displayName(for: $0) } ?? card.displayName
    }

    private var accessibilitySummary: String {
        BoardAccessibility.summary(playerCard: card)
            .replacingOccurrences(of: card.displayName, with: displayName)
    }

    var body: some View {
        linkedContainer(accessibilityLabel: accessibilitySummary) {
            VStack(alignment: .leading, spacing: 4) {
                if let imageReference = card.imageReference {
                    BoardAssetImageView(key: imageReference, description: displayName)
                        .frame(height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Text(displayName)
                    .font(.caption.bold())
                    .foregroundStyle(ArkhamTheme.bone)
                    .lineLimit(2)
                if let subtitle = card.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(card.cardCode?.rawValue ?? card.zone.displayTitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                cardBadges
            }
        }
    }

    @ViewBuilder
    private var cardBadges: some View {
        let badges = BoardCardBadgeFormatter.cardBadges(card)
        if !badges.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.25), in: Capsule())
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func linkedContainer(
        accessibilityLabel: String,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        BoardLinkedChoiceFace(
            accessibilityLabel: accessibilityLabel,
            linkedChoices: linkedChoices,
            onLinkedChoice: onLinkedChoice,
            content: content
        )
    }
}

struct BoardEnemyPanelView: View {
    let title: String
    let enemies: [BoardEnemyNode]
    let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(enemies) { enemy in
                BoardEnemyCardView(
                    enemy: enemy,
                    linkedChoices: choiceLinks[.enemy(enemy.id)] ?? [],
                    onLinkedChoice: onLinkedChoice
                )
            }
        }
    }
}

struct BoardEnemyCardView: View {
    let enemy: BoardEnemyNode
    let linkedChoices: [BoardLinkedChoice]
    let onLinkedChoice: (Int) -> Void
    @Environment(\.boardCardCatalog) private var cardCatalog

    private var displayName: String {
        enemy.cardCode.flatMap { cardCatalog?.displayName(for: $0) } ?? enemy.displayName
    }

    private var accessibilitySummary: String {
        BoardAccessibility.summary(enemy: enemy)
            .replacingOccurrences(of: enemy.displayName, with: displayName)
    }

    var body: some View {
        linkedContainer(accessibilityLabel: accessibilitySummary) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(displayName)
                        .font(.caption.bold())
                        .foregroundStyle(ArkhamTheme.bone)
                        .lineLimit(1)
                    if enemy.exhausted {
                        Text("Exhausted")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(enemy.cardCode?.rawValue ?? "Enemy")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    if let fight = enemy.fight {
                        BoardStatBadge(systemImage: "burst.fill", value: fight.displayValue)
                    }
                    if let health = enemy.health {
                        BoardStatBadge(systemImage: "heart.fill", value: health.displayValue)
                    }
                    if let evade = enemy.evade {
                        BoardStatBadge(systemImage: "figure.run", value: evade.displayValue)
                    }
                    if let damage = enemy.damage {
                        BoardStatBadge(systemImage: "heart.slash", value: "\(damage)")
                    }
                }
                .accessibilityHidden(true)
                tokenBadges
            }
        }
    }

    @ViewBuilder
    private var tokenBadges: some View {
        let badges = enemy.tokenCounts.map { "\($0.token) \($0.count)" }
        if !badges.isEmpty {
            HStack(spacing: 3) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.25), in: Capsule())
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func linkedContainer(
        accessibilityLabel: String,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        BoardLinkedChoiceFace(
            accessibilityLabel: accessibilityLabel,
            linkedChoices: linkedChoices,
            onLinkedChoice: onLinkedChoice,
            content: content
        )
    }
}

struct BoardThreatAreaView: View {
    let treacheries: [BoardThreatTreacheryNode]
    let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Threat area")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(treacheries) { treachery in
                BoardThreatTreacheryCardView(
                    treachery: treachery,
                    linkedChoices: choiceLinks[.treachery(treachery.id)] ?? [],
                    onLinkedChoice: onLinkedChoice
                )
            }
        }
    }
}

struct BoardThreatTreacheryCardView: View {
    let treachery: BoardThreatTreacheryNode
    let linkedChoices: [BoardLinkedChoice]
    let onLinkedChoice: (Int) -> Void
    @Environment(\.boardCardCatalog) private var cardCatalog

    private var displayName: String {
        treachery.cardCode.flatMap { cardCatalog?.displayName(for: $0) } ?? treachery.displayName
    }

    private var accessibilitySummary: String {
        BoardAccessibility.summary(threatTreachery: treachery)
            .replacingOccurrences(of: treachery.displayName, with: displayName)
    }

    var body: some View {
        linkedContainer(accessibilityLabel: accessibilitySummary) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.caption.bold())
                    .foregroundStyle(ArkhamTheme.bone)
                    .lineLimit(2)
                Text(treachery.cardCode?.rawValue ?? "Treachery")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if treachery.clueCount > 0 {
                    BoardStatBadge(systemImage: "sparkles", value: "\(treachery.clueCount)")
                }
            }
        }
    }

    private func linkedContainer(
        accessibilityLabel: String,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        BoardLinkedChoiceFace(
            accessibilityLabel: accessibilityLabel,
            linkedChoices: linkedChoices,
            onLinkedChoice: onLinkedChoice,
            content: content
        )
    }
}

private struct BoardLinkedChoiceFace<Content: View>: View {
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
        }
    }
}

enum BoardCardBadgeFormatter {
    static func cardBadges(_ card: BoardPlayerCardNode) -> [String] {
        var badges: [String] = []
        if let usesSummary = card.usesSummary {
            badges.append(usesSummary)
        }
        if let damage = card.damage, damage > 0 {
            badges.append("Damage \(damage)")
        }
        if let horror = card.horror, horror > 0 {
            badges.append("Horror \(horror)")
        }
        badges.append(contentsOf: card.tokenCounts.map { "\($0.token) \($0.count)" })
        return badges
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
