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
                    BoardStatBadge(
                        systemImage: "drop.fill",
                        value: BoardDisplayFormatting.pluralized(
                            counters.totalClues, singular: "clue", plural: "clues"
                        )
                    )
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
    let chaosBag: BoardChaosBagState
    let visibleChaosTokens: [BoardChaosTokenNode]
    let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    let focusedID: SemanticFocusID?
    let isFocused: Bool
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summaryTile
            linkedChaosTokenTargets
        }
    }

    private var summaryTile: some View {
        BoardEntityTile(
            id: BoardFocusID.chaosBagSummary,
            accessibilityLabel: BoardAccessibility.summary(chaosBag: chaosBag),
            isFocused: isFocused,
            focusBinding: focusBinding,
            onOutcome: onOutcome
        ) {
            VStack(alignment: .leading, spacing: 6) {
                BoardSectionHeading(title: "Chaos bag")
                chaosBagContent
            }
        }
    }

    @ViewBuilder private var chaosBagContent: some View {
        switch chaosBag.displayState {
        case .noActiveScenario:
            Text("No active scenario").font(.footnote).foregroundStyle(.secondary)
        case .empty:
            Text("Empty").font(.footnote).foregroundStyle(.secondary)
        case let .populated(summary):
            populatedChaosBagContent(summary)
        }
    }

    @ViewBuilder
    private func populatedChaosBagContent(_ summary: BoardChaosBagSummary) -> some View {
        if !summary.poolCounts.isEmpty {
            faceCountsRow(summary.poolCounts)
        }
        if !summary.revealedCounts.isEmpty {
            Text("Revealed").font(.caption2).foregroundStyle(.secondary)
            faceCountsRow(summary.revealedCounts)
        }
        if !summary.setAsideCounts.isEmpty {
            Text("Set aside").font(.caption2).foregroundStyle(.secondary)
            faceCountsRow(summary.setAsideCounts)
        }
        if let forceDrawFace = summary.forceDrawFace {
            Text("Forced draw: \(BoardDisplayFormatting.humanizeTag(forceDrawFace.rawValue))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        if summary.hasPendingChoice {
            Text("Pending chaos bag resolution")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var linkedChaosTokenTargets: some View {
        let tokens = visibleChaosTokens.filter { token in
            choiceLinks[.chaosToken(token.id)]?.isEmpty == false
        }
        if !tokens.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tokens) { token in
                        chaosTokenTarget(token)
                    }
                }
            }
        }
    }

    private func chaosTokenTarget(_ token: BoardChaosTokenNode) -> some View {
        let elementID = BoardPromptElementID.chaosToken(token.id)
        let focusID = BoardFocusID.promptElement(elementID)
        let linkedChoices = choiceLinks[elementID] ?? []
        let accessibilityLabel = BoardLocalization.format(
            "board.chaosToken.accessibility",
            "Chaos token %@",
            token.displayTitle
        )
        return BoardLinkedChoiceFace(
            accessibilityLabel: accessibilityLabel,
            linkedChoices: linkedChoices,
            focusID: focusID,
            isFocused: focusedID == focusID,
            focusBinding: focusBinding,
            onLinkedChoice: onLinkedChoice,
            onOutcome: onOutcome,
            content: {
                HStack(spacing: 6) {
                    BoardChaosTokenGlyph(face: token.face, textStyle: .caption)
                    Text(token.displayTitle)
                }
                .font(.caption)
                .foregroundStyle(token.cancelled ? .secondary : ArkhamTheme.bone)
            }
        )
    }

    private func faceCountsRow(_ counts: [BoardChaosFaceCount]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(counts, id: \.face) { count in
                    BoardChaosFaceCountBadge(count: count)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct BoardChaosTokenGlyph: View {
    let face: ChaosTokenFace
    let textStyle: StoryInlineTextStyle

    var body: some View {
        if let nodes = BoardChaosTokenGlyphPresentation.nodes(for: face) {
            StoryInlineTextLabel(fallbackText: "", nodes: nodes, textStyle: textStyle)
        } else {
            Image(systemName: BoardChaosTokenGlyphPresentation.fallbackSystemImage)
        }
    }
}

private struct BoardChaosFaceCountBadge: View {
    let count: BoardChaosFaceCount

    var body: some View {
        HStack(spacing: 4) {
            BoardChaosTokenGlyph(face: count.face, textStyle: .caption)
            Text("\(BoardDisplayFormatting.humanizeTag(count.face.rawValue)) ×\(count.count)")
                .font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.25), in: Capsule())
        .accessibilityHidden(true)
    }
}
