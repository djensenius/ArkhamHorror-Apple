import SwiftUI

/// The investigator row — the board's single "board.investigators" zone, ordered by
/// `PublicGame.playerOrder`.
struct BoardInvestigatorRowView: View {
    let investigators: [BoardInvestigatorNode]
    let otherInvestigatorCount: Int
    let killedInvestigatorCount: Int
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void

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
                let otherPhrase = BoardDisplayFormatting.pluralized(
                    otherInvestigatorCount, singular: "other investigator",
                    plural: "other investigators"
                )
                let killedPhrase = BoardDisplayFormatting.pluralized(
                    killedInvestigatorCount, singular: "killed investigator",
                    plural: "killed investigators"
                )
                Text("\(otherPhrase), \(killedPhrase)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tile(_ investigator: BoardInvestigatorNode) -> some View {
        let id = BoardFocusID.investigator(investigator.id)
        return BoardEntityTile(
            id: id,
            accessibilityLabel: BoardAccessibility.summary(investigator: investigator),
            isFocused: focusedID == id,
            focusBinding: focusBinding,
            onOutcome: onOutcome
        ) {
            VStack(spacing: 4) {
                Text(investigator.displayName)
                    .font(.subheadline.bold())
                    .foregroundStyle(ArkhamTheme.bone)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    BoardStatBadge(systemImage: "heart.fill", value: "\(investigator.health)")
                    BoardStatBadge(
                        systemImage: "brain.head.profile", value: "\(investigator.sanity)"
                    )
                    BoardStatBadge(
                        systemImage: "bolt.fill", value: "\(investigator.remainingActions)"
                    )
                }
                if investigator.isActiveInvestigator {
                    Text("Active").font(.caption2).foregroundStyle(ArkhamTheme.accent)
                }
                statusBadges(investigator)
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
