import SwiftUI

enum BoardInvestigatorDisplayNames {
    static func map(_ investigators: [BoardInvestigatorNode]) -> [InvestigatorID: String] {
        Dictionary(investigators.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in
            first
        })
    }
}

enum BoardPlayerAreaVisibility {
    static func shouldShowFullArea(
        for investigator: BoardInvestigatorNode,
        fullPlayerAreaPlayerID: PlayerID?
    ) -> Bool {
        if let fullPlayerAreaPlayerID {
            return investigator.playerID == fullPlayerAreaPlayerID
        }
        return investigator.isActiveInvestigator
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
        .frame(width: 272, alignment: .top)
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
            if investigator.isActiveInvestigator {
                Text("Active").font(.caption2).foregroundStyle(ArkhamTheme.accent)
            }
            statusBadges(investigator)
        }
    }

    @ViewBuilder
    private func investigatorPlayerArea(_ investigator: BoardInvestigatorNode) -> some View {
        if shouldShowFullArea(for: investigator) {
            BoardPlayerAreaView(
                investigator: investigator,
                handCards: handCardsByPlayer[investigator.playerID] ?? [],
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
        // Fixture/gallery boards and spectator sessions may have no local participant
        // identity; in that case keep the previous active-investigator fallback so one
        // full player area remains visible instead of collapsing every hand/play area.
        BoardPlayerAreaVisibility.shouldShowFullArea(
            for: investigator,
            fullPlayerAreaPlayerID: fullPlayerAreaPlayerID
        )
    }

    private func compactPlayerArea(_ investigator: BoardInvestigatorNode) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            let handCount = handCardsByPlayer[investigator.playerID]?.count ?? 0
            let inPlayCount = inPlayCardsByPlayer[investigator.playerID]?.count ?? 0
            Text("Hand \(handCount), in play \(inPlayCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
