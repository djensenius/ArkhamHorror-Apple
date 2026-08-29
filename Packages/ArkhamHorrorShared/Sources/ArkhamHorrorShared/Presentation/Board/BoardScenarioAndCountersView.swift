import SwiftUI

/// The scenario/reference header and its accompanying phase/turn/counter summary — the
/// board's single "board.scenario" zone entity.
struct BoardScenarioHeaderView: View {
    let scenario: BoardScenarioSummary?
    let hasCampaignContext: Bool
    let counters: BoardCounters
    let isFocused: Bool
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void

    private var accessibilityLabel: String {
        BoardAccessibility.summary(scenario: scenario, hasCampaignContext: hasCampaignContext)
            + ". " + BoardAccessibility.summary(counters: counters)
    }

    var body: some View {
        BoardEntityTile(
            id: BoardFocusID.scenarioHeader,
            accessibilityLabel: accessibilityLabel,
            isFocused: isFocused,
            focusBinding: focusBinding,
            onOutcome: onOutcome
        ) {
            VStack(alignment: .leading, spacing: 8) {
                titleBlock
                HStack(spacing: 8) {
                    BoardStatBadge(
                        systemImage: "theatermask.and.paintbrush",
                        value: BoardDisplayFormatting.humanizeTag(counters.phase.rawValue)
                    )
                    BoardStatBadge(systemImage: "drop.fill", value: "\(counters.totalClues) clues")
                    BoardStatBadge(systemImage: "flame.fill", value: "\(counters.totalDoom) doom")
                    if counters.pendingPromptCount > 0 {
                        BoardStatBadge(
                            systemImage: "exclamationmark.bubble.fill",
                            value: BoardDisplayFormatting.pluralized(
                                counters.pendingPromptCount, singular: "prompt", plural: "prompts"
                            )
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder private var titleBlock: some View {
        if let scenario {
            Text(scenario.displayName)
                .font(.title3.bold())
                .foregroundStyle(ArkhamTheme.bone)
            if let subtitle = scenario.subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(ArkhamTheme.bone.opacity(0.7))
            }
            HStack(spacing: 8) {
                BoardStatBadge(systemImage: "dial.medium", value: scenario.difficulty.rawValue)
                BoardStatBadge(systemImage: "clock", value: "Turn \(scenario.turn)")
            }
        } else if hasCampaignContext {
            Text("Campaign summary").font(.title3.bold()).foregroundStyle(ArkhamTheme.bone)
            Text(BoardDisplayFormatting.unsupportedContentNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Text("No active scenario").font(.title3.bold()).foregroundStyle(ArkhamTheme.bone)
        }
    }
}

/// The scenario's chaos bag summary — the board's single "board.chaosBag" zone entity.
struct BoardChaosBagView: View {
    let chaosBag: BoardChaosBagSummary
    let isFocused: Bool
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void

    var body: some View {
        BoardEntityTile(
            id: BoardFocusID.chaosBagSummary,
            accessibilityLabel: BoardAccessibility.summary(chaosBag: chaosBag),
            isFocused: isFocused,
            focusBinding: focusBinding,
            onOutcome: onOutcome
        ) {
            VStack(alignment: .leading, spacing: 6) {
                BoardSectionHeading(title: "Chaos bag")
                if chaosBag.isEntirelyEmpty {
                    Text(BoardDisplayFormatting.unsupportedContentNotice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    if !chaosBag.poolCounts.isEmpty {
                        faceCountsRow(chaosBag.poolCounts)
                    }
                    if !chaosBag.revealedCounts.isEmpty {
                        Text("Revealed").font(.caption2).foregroundStyle(.secondary)
                        faceCountsRow(chaosBag.revealedCounts)
                    }
                    if !chaosBag.setAsideCounts.isEmpty {
                        Text("Set aside").font(.caption2).foregroundStyle(.secondary)
                        faceCountsRow(chaosBag.setAsideCounts)
                    }
                    if let forceDrawFace = chaosBag.forceDrawFace {
                        Text("Forced draw: \(forceDrawFace.rawValue)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if chaosBag.hasPendingChoice {
                        Text("Pending chaos bag resolution")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func faceCountsRow(_ counts: [BoardChaosFaceCount]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(counts, id: \.face) { count in
                    BoardStatBadge(
                        systemImage: "circle.hexagongrid.fill",
                        value: "\(count.face.rawValue) ×\(count.count)"
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}
