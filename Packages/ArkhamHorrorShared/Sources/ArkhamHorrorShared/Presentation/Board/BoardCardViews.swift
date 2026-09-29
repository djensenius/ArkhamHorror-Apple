import SwiftUI

struct BoardPlayerAreaView: View {
    let investigator: BoardInvestigatorNode
    let handCards: [BoardPlayerCardNode]
    let inPlayCards: [BoardPlayerCardNode]
    let threatTreacheries: [BoardThreatTreacheryNode]
    let engagedEnemies: [BoardEnemyNode]
    let choiceLinks: [BoardPromptElementID: BoardLinkedChoice]
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
                            linkedChoice: choiceLinks[.playerCard(card.id)],
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
    let linkedChoice: BoardLinkedChoice?
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        linkedContainer(accessibilityLabel: BoardAccessibility.summary(playerCard: card)) {
            VStack(alignment: .leading, spacing: 4) {
                if let imageReference = card.imageReference {
                    StoryAssetImageView(reference: imageReference)
                        .frame(height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Text(card.displayName)
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

    @ViewBuilder
    private func linkedContainer(
        accessibilityLabel: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if let linkedChoice, linkedChoice.isActionable {
            Button {
                onLinkedChoice(linkedChoice.choiceIndex)
            } label: {
                content()
                    .cardFaceStyle(linkedChoice: linkedChoice)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityHint(Text("Activates \(linkedChoice.title)"))
        } else {
            content()
                .cardFaceStyle(linkedChoice: linkedChoice)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityLabel))
        }
    }
}

struct BoardEnemyPanelView: View {
    let title: String
    let enemies: [BoardEnemyNode]
    let choiceLinks: [BoardPromptElementID: BoardLinkedChoice]
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(enemies) { enemy in
                BoardEnemyCardView(
                    enemy: enemy,
                    linkedChoice: choiceLinks[.enemy(enemy.id)],
                    onLinkedChoice: onLinkedChoice
                )
            }
        }
    }
}

struct BoardEnemyCardView: View {
    let enemy: BoardEnemyNode
    let linkedChoice: BoardLinkedChoice?
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        linkedContainer(accessibilityLabel: BoardAccessibility.summary(enemy: enemy)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(enemy.displayName)
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
                        BoardStatBadge(systemImage: "burst.fill", value: "\(fight)")
                    }
                    if let health = enemy.health {
                        BoardStatBadge(systemImage: "heart.fill", value: "\(health)")
                    }
                    if let evade = enemy.evade {
                        BoardStatBadge(systemImage: "figure.run", value: "\(evade)")
                    }
                    if let damage = enemy.damage {
                        BoardStatBadge(systemImage: "heart.slash", value: "\(damage)")
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func linkedContainer(
        accessibilityLabel: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if let linkedChoice, linkedChoice.isActionable {
            Button { onLinkedChoice(linkedChoice.choiceIndex) } label: {
                content().cardFaceStyle(linkedChoice: linkedChoice)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityHint(Text("Activates \(linkedChoice.title)"))
        } else {
            content()
                .cardFaceStyle(linkedChoice: linkedChoice)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityLabel))
        }
    }
}

struct BoardThreatAreaView: View {
    let treacheries: [BoardThreatTreacheryNode]
    let choiceLinks: [BoardPromptElementID: BoardLinkedChoice]
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Threat area")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(treacheries) { treachery in
                BoardThreatTreacheryCardView(
                    treachery: treachery,
                    linkedChoice: choiceLinks[.treachery(treachery.id)],
                    onLinkedChoice: onLinkedChoice
                )
            }
        }
    }
}

struct BoardThreatTreacheryCardView: View {
    let treachery: BoardThreatTreacheryNode
    let linkedChoice: BoardLinkedChoice?
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        linkedContainer(
            accessibilityLabel: BoardAccessibility.summary(threatTreachery: treachery)
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(treachery.displayName)
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

    @ViewBuilder
    private func linkedContainer(
        accessibilityLabel: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if let linkedChoice, linkedChoice.isActionable {
            Button { onLinkedChoice(linkedChoice.choiceIndex) } label: {
                content().cardFaceStyle(linkedChoice: linkedChoice)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityHint(Text("Activates \(linkedChoice.title)"))
        } else {
            content()
                .cardFaceStyle(linkedChoice: linkedChoice)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityLabel))
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
    func cardFaceStyle(linkedChoice: BoardLinkedChoice?) -> some View {
        padding(8)
            .frame(width: 116, alignment: .leading)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        outlineColor(linkedChoice),
                        lineWidth: linkedChoice == nil ? 1 : 3
                    )
            }
    }

    private func outlineColor(_ linkedChoice: BoardLinkedChoice?) -> Color {
        guard let linkedChoice else { return .white.opacity(0.12) }
        return linkedChoice.isActionable ? ArkhamTheme.accent : .orange.opacity(0.45)
    }
}
