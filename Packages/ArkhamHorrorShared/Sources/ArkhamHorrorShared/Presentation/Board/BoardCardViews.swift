import SwiftUI

extension EnvironmentValues {
    @Entry var boardCardCatalog: CardCatalogSnapshot?
}

struct BoardHiddenHandBackView: View {
    let placeholder: BoardHiddenHandBackPlaceholder

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.black.opacity(0.45))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(ArkhamTheme.accent.opacity(0.6), lineWidth: 1)
            }
            .overlay {
                Image(systemName: "rectangle.portrait.fill")
                    .font(.caption)
                    .foregroundStyle(ArkhamTheme.bone.opacity(0.65))
                    .accessibilityHidden(true)
            }
            .frame(width: 32, height: 44)
            .accessibilityLabel(placeholder.accessibilityLabel)
    }
}

struct BoardPlayerAreaView: View {
    let investigator: BoardInvestigatorNode
    let deckCountBadge: BoardDeckCountBadgeModel
    let handCards: [BoardPlayerCardNode]
    let inPlayCards: [BoardPlayerCardNode]
    let threatTreacheries: [BoardThreatTreacheryNode]
    let engagedEnemies: [BoardEnemyNode]
    let investigatorDisplayNames: [InvestigatorID: String]
    let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            deckCountView
            if !handCards.isEmpty {
                cardStrip(title: "Hand", cards: handCards)
            }
            if !inPlayCards.isEmpty {
                cardStrip(title: "Play area", cards: inPlayCards)
            }
            if !engagedEnemies.isEmpty {
                BoardEnemyPanelView(
                    title: "Engaged", enemies: engagedEnemies,
                    investigatorDisplayNames: investigatorDisplayNames,
                    choiceLinks: choiceLinks,
                    focusedID: focusedID,
                    focusBinding: focusBinding,
                    onOutcome: onOutcome,
                    onLinkedChoice: onLinkedChoice
                )
            }
            if !threatTreacheries.isEmpty {
                BoardThreatAreaView(
                    treacheries: threatTreacheries,
                    choiceLinks: choiceLinks,
                    focusedID: focusedID,
                    focusBinding: focusBinding,
                    onOutcome: onOutcome,
                    onLinkedChoice: onLinkedChoice
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(investigator.displayName) player area")
    }

    private var deckCountView: some View {
        HStack(spacing: 4) {
            Text("Deck")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Image(systemName: "rectangle.stack.fill")
                .font(.caption2)
                .foregroundStyle(ArkhamTheme.accent)
                .accessibilityHidden(true)
            Text(deckCountBadge.value)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(ArkhamTheme.bone)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(deckCountBadge.accessibilityLabel)
    }

    private func cardStrip(title: String, cards: [BoardPlayerCardNode]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 6) {
                ForEach(cards) { card in
                    BoardPlayerCardFaceView(
                        card: card,
                        linkedChoices: choiceLinks[.playerCard(card.id)] ?? [],
                        focusedID: focusedID,
                        focusBinding: focusBinding,
                        onOutcome: onOutcome,
                        onLinkedChoice: onLinkedChoice
                    )
                }
            }
        }
    }
}

struct BoardPlayerCardFaceView: View {
    let card: BoardPlayerCardNode
    let linkedChoices: [BoardLinkedChoice]
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void
    let onLinkedChoice: (Int) -> Void
    @Environment(\.boardCardCatalog) private var cardCatalog

    private var displayName: String {
        card.cardCode.flatMap { cardCatalog?.displayName(for: $0) } ?? card.displayName
    }

    private var accessibilitySummary: String {
        BoardAccessibility.summary(playerCard: card, displayName: displayName)
    }

    private var linkedFocusID: SemanticFocusID? {
        switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
        case .submit, .menu: BoardFocusID.promptElement(.playerCard(card.id))
        case .highlightOnly: nil
        }
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
            focusID: linkedFocusID,
            isFocused: focusedID == linkedFocusID,
            focusBinding: focusBinding,
            onLinkedChoice: onLinkedChoice,
            onOutcome: onOutcome,
            content: content
        )
    }
}

struct BoardEnemyPanelView: View {
    let title: String
    let enemies: [BoardEnemyNode]
    var investigatorDisplayNames: [InvestigatorID: String] = [:]
    let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(enemies) { enemy in
                BoardEnemyCardView(
                    enemy: enemy,
                    investigatorDisplayNames: investigatorDisplayNames,
                    linkedChoices: choiceLinks[.enemy(enemy.id)] ?? [],
                    focusedID: focusedID,
                    focusBinding: focusBinding,
                    onOutcome: onOutcome,
                    onLinkedChoice: onLinkedChoice
                )
            }
        }
    }
}

struct BoardEnemyCardView: View {
    let enemy: BoardEnemyNode
    let investigatorDisplayNames: [InvestigatorID: String]
    let linkedChoices: [BoardLinkedChoice]
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void
    let onLinkedChoice: (Int) -> Void
    @Environment(\.boardCardCatalog) private var cardCatalog

    private var displayName: String {
        enemy.cardCode.flatMap { cardCatalog?.displayName(for: $0) } ?? enemy.displayName
    }

    private var accessibilitySummary: String {
        BoardAccessibility.summary(
            enemy: enemy,
            displayName: displayName,
            engagedInvestigatorName: enemy.engagedInvestigatorID.flatMap {
                investigatorDisplayNames[$0]
            }
        )
    }

    private var linkedFocusID: SemanticFocusID? {
        switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
        case .submit, .menu: BoardFocusID.promptElement(.enemy(enemy.id))
        case .highlightOnly: nil
        }
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
                    if let attackDamage = enemy.attackDamage {
                        BoardStatBadge(systemImage: "heart.slash", value: "Atk \(attackDamage)")
                    }
                    if let attackHorror = enemy.attackHorror {
                        BoardStatBadge(
                            systemImage: "brain.head.profile", value: "Atk \(attackHorror)"
                        )
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
            focusID: linkedFocusID,
            isFocused: focusedID == linkedFocusID,
            focusBinding: focusBinding,
            onLinkedChoice: onLinkedChoice,
            onOutcome: onOutcome,
            content: content
        )
    }
}

struct BoardThreatAreaView: View {
    let treacheries: [BoardThreatTreacheryNode]
    let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void
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
                    focusedID: focusedID,
                    focusBinding: focusBinding,
                    onOutcome: onOutcome,
                    onLinkedChoice: onLinkedChoice
                )
            }
        }
    }
}

struct BoardThreatTreacheryCardView: View {
    let treachery: BoardThreatTreacheryNode
    let linkedChoices: [BoardLinkedChoice]
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void
    let onLinkedChoice: (Int) -> Void
    @Environment(\.boardCardCatalog) private var cardCatalog

    private var displayName: String {
        treachery.cardCode.flatMap { cardCatalog?.displayName(for: $0) } ?? treachery.displayName
    }

    private var accessibilitySummary: String {
        BoardAccessibility.summary(threatTreachery: treachery, displayName: displayName)
    }

    private var linkedFocusID: SemanticFocusID? {
        switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
        case .submit, .menu: BoardFocusID.promptElement(.treachery(treachery.id))
        case .highlightOnly: nil
        }
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
            focusID: linkedFocusID,
            isFocused: focusedID == linkedFocusID,
            focusBinding: focusBinding,
            onLinkedChoice: onLinkedChoice,
            onOutcome: onOutcome,
            content: content
        )
    }
}
