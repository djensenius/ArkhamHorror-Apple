import SwiftUI

enum BoardInvestigatorDisplayNames {
    static func map(_ investigators: [BoardInvestigatorNode]) -> [InvestigatorID: String] {
        Dictionary(investigators.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in
            first
        })
    }
}

struct BoardHiddenHandBackPlaceholder: Sendable, Equatable, Identifiable {
    let id: Int
    let cardID: BoardPlayerCardID? = nil
    let accessibilityLabel = "Hidden hand card"
}

struct BoardHiddenHandBackFanLayout: Sendable, Equatable {
    let spacing: CGFloat
    let totalWidth: CGFloat

    static func make(
        handCount: Int,
        availableWidth: CGFloat = BoardInvestigatorTileLayout.width,
        cardWidth: CGFloat = BoardInvestigatorTileLayout.hiddenHandBackSize.width,
        preferredSpacing: CGFloat = BoardInvestigatorTileLayout.hiddenHandBackSpacing
    ) -> BoardHiddenHandBackFanLayout {
        guard handCount > 0 else {
            return BoardHiddenHandBackFanLayout(spacing: preferredSpacing, totalWidth: 0)
        }
        guard handCount > 1 else {
            return BoardHiddenHandBackFanLayout(
                spacing: preferredSpacing,
                totalWidth: min(cardWidth, availableWidth)
            )
        }

        let gaps = CGFloat(handCount - 1)
        let preferredWidth = cardWidth * CGFloat(handCount) + preferredSpacing * gaps
        guard preferredWidth > availableWidth else {
            return BoardHiddenHandBackFanLayout(
                spacing: preferredSpacing,
                totalWidth: preferredWidth
            )
        }

        let overlappedSpacing = (availableWidth - cardWidth * CGFloat(handCount)) / gaps
        return BoardHiddenHandBackFanLayout(
            spacing: overlappedSpacing,
            totalWidth: availableWidth
        )
    }
}

enum BoardInvestigatorTileLayout {
    static let width: CGFloat = 272
    static let hiddenHandBackSize = CGSize(width: 32, height: 44)
    static let hiddenHandBackSpacing: CGFloat = 4
}

struct BoardDeckCountBadgeModel: Sendable, Equatable {
    let count: Int

    var value: String {
        "\(count)"
    }

    var accessibilityLabel: String {
        "Deck " + BoardDisplayFormatting.pluralized(
            count, singular: "card", plural: "cards"
        )
    }
}

enum BoardPlayerAreaVisibility {
    static func shouldShowFullArea(
        for investigator: BoardInvestigatorNode,
        fullPlayerAreaPlayerID: PlayerID?,
        isSolo: Bool = false
    ) -> Bool {
        if let fullPlayerAreaPlayerID {
            return investigator.playerID == fullPlayerAreaPlayerID
        }
        return isSolo && investigator.isActiveInvestigator
    }

    static func revealsHandCardFaces(
        for investigator: BoardInvestigatorNode,
        localPlayerID: PlayerID?,
        isSolo: Bool
    ) -> Bool {
        isSolo || investigator.playerID == localPlayerID
    }

    static func visibleHandCards(
        for investigator: BoardInvestigatorNode,
        cardsByPlayer: [PlayerID: [BoardPlayerCardNode]],
        localPlayerID: PlayerID?,
        isSolo: Bool
    ) -> [BoardPlayerCardNode] {
        guard revealsHandCardFaces(
            for: investigator, localPlayerID: localPlayerID, isSolo: isSolo
        ) else { return [] }
        return cardsByPlayer[investigator.playerID] ?? []
    }

    static func hiddenHandBackPlaceholders(
        for investigator: BoardInvestigatorNode,
        localPlayerID: PlayerID?,
        isSolo: Bool
    ) -> [BoardHiddenHandBackPlaceholder] {
        guard !revealsHandCardFaces(
            for: investigator, localPlayerID: localPlayerID, isSolo: isSolo
        ) else { return [] }
        return (0 ..< investigator.handCount).map(BoardHiddenHandBackPlaceholder.init(id:))
    }

    static func deckCountBadge(
        for investigator: BoardInvestigatorNode
    ) -> BoardDeckCountBadgeModel {
        BoardDeckCountBadgeModel(count: investigator.deckCount)
    }
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
            .frame(
                width: BoardInvestigatorTileLayout.hiddenHandBackSize.width,
                height: BoardInvestigatorTileLayout.hiddenHandBackSize.height
            )
            .accessibilityLabel(placeholder.accessibilityLabel)
    }
}

/// The investigator row — the board's single "board.investigators" zone, ordered by
/// `PublicGame.playerOrder`.
struct BoardInvestigatorRowView: View {
    let investigators: [BoardInvestigatorNode]
    let handCardsByPlayer: [PlayerID: [BoardPlayerCardNode]]
    let inPlayCardsByPlayer: [PlayerID: [BoardPlayerCardNode]]
    let threatTreacheriesByPlayer: [PlayerID: [BoardThreatTreacheryNode]]
    let engagedEnemiesByInvestigatorID: [InvestigatorID: [BoardEnemyNode]]
    let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    let fullPlayerAreaPlayerID: PlayerID?
    let localPlayerID: PlayerID?
    let isSolo: Bool
    let otherInvestigatorCount: Int
    let killedInvestigatorCount: Int
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BoardSectionHeading(title: "Investigators")
            if investigators.isEmpty {
                Text("No investigators in this scenario")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(investigators) { investigator in
                            tile(investigator)
                        }
                    }
                }
            }
            if otherInvestigatorCount > 0 || killedInvestigatorCount > 0 {
                Text(otherAndKilledInvestigatorSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Builds the "other/killed investigator" footer from only the categories that are
    /// actually non-zero, so it never announces a "0 other investigators"/"0 killed
    /// investigators" phrase alongside a genuinely populated category.
    private var otherAndKilledInvestigatorSummary: String {
        var phrases: [String] = []
        if otherInvestigatorCount > 0 {
            phrases.append(BoardDisplayFormatting.pluralized(
                otherInvestigatorCount, singular: "other investigator",
                plural: "other investigators"
            ))
        }
        if killedInvestigatorCount > 0 {
            phrases.append(BoardDisplayFormatting.pluralized(
                killedInvestigatorCount, singular: "killed investigator",
                plural: "killed investigators"
            ))
        }
        return phrases.joined(separator: ", ")
    }

    private func tile(_ investigator: BoardInvestigatorNode) -> some View {
        let id = BoardFocusID.investigator(investigator.id)
        return VStack(spacing: 8) {
            BoardEntityTile(
                id: id,
                accessibilityLabel: BoardAccessibility.summary(investigator: investigator),
                isFocused: focusedID == id,
                focusBinding: focusBinding,
                onOutcome: onOutcome
            ) {
                investigatorSummary(investigator)
            }
            investigatorPlayerArea(investigator)
        }
        .frame(width: BoardInvestigatorTileLayout.width, alignment: .top)
        .accessibilityElement(children: .contain)
    }

    private func investigatorSummary(_ investigator: BoardInvestigatorNode) -> some View {
        VStack(spacing: 4) {
            Text(investigator.displayName)
                .font(.subheadline.bold())
                .foregroundStyle(ArkhamTheme.bone)
                .lineLimit(1)
            HStack(spacing: 4) {
                BoardStatBadge(systemImage: "heart.fill", value: "\(investigator.health)")
                BoardStatBadge(systemImage: "brain.head.profile", value: "\(investigator.sanity)")
                BoardStatBadge(systemImage: "bolt.fill", value: "\(investigator.remainingActions)")
            }
            roleBadges(investigator)
            statusBadges(investigator)
        }
    }

    @ViewBuilder
    private func investigatorPlayerArea(_ investigator: BoardInvestigatorNode) -> some View {
        if shouldShowFullArea(for: investigator) {
            BoardPlayerAreaView(
                investigator: investigator,
                deckCountBadge: BoardPlayerAreaVisibility.deckCountBadge(for: investigator),
                handCards: BoardPlayerAreaVisibility.visibleHandCards(
                    for: investigator,
                    cardsByPlayer: handCardsByPlayer,
                    localPlayerID: localPlayerID,
                    isSolo: isSolo
                ),
                inPlayCards: inPlayCardsByPlayer[investigator.playerID] ?? [],
                threatTreacheries: threatTreacheriesByPlayer[investigator.playerID] ?? [],
                engagedEnemies: engagedEnemiesByInvestigatorID[investigator.id] ?? [],
                investigatorDisplayNames: investigatorDisplayNamesByID,
                choiceLinks: choiceLinks,
                focusedID: focusedID,
                focusBinding: focusBinding,
                onOutcome: onOutcome,
                onLinkedChoice: onLinkedChoice
            )
        } else {
            compactPlayerArea(investigator)
        }
    }

    private var investigatorDisplayNamesByID: [InvestigatorID: String] {
        BoardInvestigatorDisplayNames.map(investigators)
    }

    private func shouldShowFullArea(for investigator: BoardInvestigatorNode) -> Bool {
        // Fixture/gallery boards and solo spectator sessions may have no local participant
        // identity; in that case keep the active-investigator fallback so one solo hand
        // remains visible. With-friends spectators get compact count-only rows instead.
        BoardPlayerAreaVisibility.shouldShowFullArea(
            for: investigator,
            fullPlayerAreaPlayerID: fullPlayerAreaPlayerID,
            isSolo: isSolo
        )
    }

    private func compactPlayerArea(_ investigator: BoardInvestigatorNode) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            let handCount = investigator.handCount
            let deckCount = investigator.deckCount
            let inPlayCount = inPlayCardsByPlayer[investigator.playerID]?.count ?? 0
            Text("Hand \(handCount), deck \(deckCount), in play \(inPlayCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            hiddenHandBackStrip(for: investigator)
            if let enemies = engagedEnemiesByInvestigatorID[investigator.id], !enemies.isEmpty {
                BoardEnemyPanelView(
                    title: "Engaged", enemies: enemies,
                    investigatorDisplayNames: investigatorDisplayNamesByID,
                    choiceLinks: choiceLinks,
                    focusedID: focusedID,
                    focusBinding: focusBinding,
                    onOutcome: onOutcome,
                    onLinkedChoice: onLinkedChoice
                )
            }
            if let treacheries = threatTreacheriesByPlayer[investigator.playerID] {
                if !treacheries.isEmpty {
                    BoardThreatAreaView(
                        treacheries: treacheries,
                        choiceLinks: choiceLinks,
                        focusedID: focusedID,
                        focusBinding: focusBinding,
                        onOutcome: onOutcome,
                        onLinkedChoice: onLinkedChoice
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func hiddenHandBackStrip(for investigator: BoardInvestigatorNode) -> some View {
        let placeholders = BoardPlayerAreaVisibility.hiddenHandBackPlaceholders(
            for: investigator,
            localPlayerID: localPlayerID,
            isSolo: isSolo
        )
        if !placeholders.isEmpty {
            let layout = BoardHiddenHandBackFanLayout.make(handCount: placeholders.count)
            HStack(alignment: .top, spacing: layout.spacing) {
                ForEach(placeholders) { placeholder in
                    BoardHiddenHandBackView(placeholder: placeholder)
                }
            }
            .frame(width: layout.totalWidth, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Hand " + BoardDisplayFormatting.pluralized(
                    placeholders.count, singular: "hidden card", plural: "hidden cards"
                )
            )
        }
    }

    @ViewBuilder
    private func roleBadges(_ investigator: BoardInvestigatorNode) -> some View {
        let labels = roleLabels(for: investigator)
        if !labels.isEmpty {
            HStack(spacing: 4) {
                ForEach(labels, id: \.self) { label in
                    roleChip(label)
                }
            }
        }
    }

    private func roleLabels(for investigator: BoardInvestigatorNode) -> [String] {
        var labels: [String] = []
        if investigator.isActingPlayer {
            labels.append(BoardLocalization.localized("board.role.active", "Active"))
        }
        if investigator.isMultiplayer, investigator.isTurnPlayer {
            labels.append(BoardLocalization.localized("board.role.turn", "Turn"))
        }
        if investigator.isMultiplayer, investigator.isLeadInvestigator {
            labels.append(BoardLocalization.localized("board.role.lead", "Lead"))
        }
        if investigator.isMultiplayer, investigator.hasPendingPrompt {
            labels.append(BoardLocalization.localized("board.role.prompt", "Prompt"))
        }
        return labels
    }

    private func roleChip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .background(ArkhamTheme.accent.opacity(0.25), in: Capsule())
            .foregroundStyle(ArkhamTheme.accent)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func statusBadges(_ investigator: BoardInvestigatorNode) -> some View {
        let hasAnyStatus = investigator.defeated || investigator.resigned
            || investigator.eliminated || investigator.drivenInsane
        if hasAnyStatus {
            HStack(spacing: 4) {
                if investigator.defeated {
                    statusChip("Defeated")
                }
                if investigator.resigned {
                    statusChip("Resigned")
                }
                if investigator.eliminated {
                    statusChip("Eliminated")
                }
                if investigator.drivenInsane {
                    statusChip("Insane")
                }
            }
        }
    }

    private func statusChip(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(.red.opacity(0.35), in: Capsule())
            .accessibilityHidden(true)
    }
}
