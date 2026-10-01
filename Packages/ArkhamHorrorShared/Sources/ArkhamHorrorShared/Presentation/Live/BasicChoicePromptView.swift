import SwiftUI

// swiftlint:disable:next type_body_length
struct BasicChoicePromptView: View {
    let presentation: BasicChoicePromptPresentation
    let controller: BoardCommandController
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let isCompact: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isStoryPrompt: Bool {
        presentation.isStoryPrompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        presentation.headerTitle(in: controller.projection),
                        systemImage: isStoryPrompt ? "book.closed.fill" : "questionmark.circle.fill"
                    )
                    .font(.headline)
                    if let subtitle = presentation.headerSubtitle(in: controller.projection) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("Step \(presentation.questionVersion)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let skillTest = controller.projection.skillTest {
                SkillTestSummaryView(projection: skillTest)
            }

            if !presentation.isRenderableQuestion {
                Label("Update required", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if let amountPrompt = presentation.amountPrompt(in: controller.projection) {
                amountAllocationPrompt(amountPrompt)
            } else if let exchangePrompt = presentation.exchangePrompt(in: controller.projection) {
                exchangeAmountPrompt(exchangePrompt)
            } else {
                if isStoryPrompt {
                    story
                }
                if let hint = presentation.questionHint() {
                    Text(hint)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("liveGame.prompt.selectionHint")
                }
                choices
            }

            if let message = presentation.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("liveGame.prompt.status")
            }

            if let feedback = presentation.serverFeedback {
                Label(feedback, systemImage: "exclamationmark.bubble")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("liveGame.prompt.serverFeedback")
            }

            if presentation.canRetry {
                SemanticActionControl(
                    accessibilityLabel: Text("Retry choice"),
                    semanticFocusID: BoardFocusID.promptRetry,
                    onOutcome: { controller.handle(focusID: $0, $1) },
                    label: { Text("Retry choice") }
                )
                .buttonStyle(.borderedProminent)
                .focused(focusBinding, equals: BoardFocusID.promptRetry)
                .accessibilityHint("Sends the same choice again with version checking.")
                .accessibilityIdentifier("liveGame.prompt.retry")
            }

            if let retry = presentation.catalogRetry {
                SemanticActionControl(
                    accessibilityLabel: Text(retry.title),
                    semanticFocusID: BoardFocusID.promptCatalogRetry,
                    onOutcome: { controller.handle(focusID: $0, $1) },
                    label: { Text(retry.title) }
                )
                .buttonStyle(.borderedProminent)
                .focused(focusBinding, equals: BoardFocusID.promptCatalogRetry)
                .accessibilityHint(retry.accessibilityHint)
                .accessibilityIdentifier("liveGame.prompt.catalogRetry")
            }
        }
        .padding(isCompact ? 14 : 18)
        .frame(maxWidth: isCompact ? .infinity : 360, alignment: .leading)
        .background(background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isStoryPrompt ? "Active story prompt" : "Active choice prompt")
        .accessibilityIdentifier("liveGame.prompt")
    }

    @ViewBuilder
    private var story: some View {
        if let content = presentation.question.supportedQuestion?.story {
            VStack(alignment: .leading, spacing: 8) {
                if let resolved = presentation.storyResolution?.story {
                    if let title = resolved.title {
                        Text(title)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("liveGame.prompt.story.title")
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(
                                Array(resolved.body.enumerated()), id: \.offset
                            ) { _, entry in
                                ResolvedStoryEntryView(entry: entry)
                            }
                        }
                    }
                    .frame(maxHeight: isCompact ? 240 : 420)
                    .accessibilityIdentifier("liveGame.prompt.story.body")
                } else {
                    Label(
                        presentation.storyResolution?.unavailableReason?.announcement
                            ?? "This story text is not currently available.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("liveGame.prompt.story.unavailable")
                }
                if let readCards = content.readCards, !readCards.isEmpty {
                    readCardsSummary(readCards)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("liveGame.prompt.story")
        } else if presentation.semanticPresentation?.presentation.flavorText != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let resolved = presentation.storyResolution?.story {
                    if let title = resolved.title {
                        Text(title)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("liveGame.prompt.story.title")
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(resolved.body.enumerated()), id: \.offset) { _, entry in
                                ResolvedStoryEntryView(entry: entry)
                            }
                        }
                    }
                    .frame(maxHeight: isCompact ? 240 : 420)
                    .accessibilityIdentifier("liveGame.prompt.story.body")
                } else {
                    Label(
                        presentation.storyResolution?.unavailableReason?.announcement
                            ?? "This story text is not currently available.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("liveGame.prompt.story.unavailable")
                }
                if let codes = presentation.semanticPresentation?.presentation.readCards {
                    if !codes.isEmpty {
                        genericReadCardsSummary(codes)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("liveGame.prompt.story")
        }
    }

    private func readCardsSummary(_ codes: [CardCode]) -> some View {
        genericReadCardsSummary(codes.map(\.rawValue))
    }

    private func genericReadCardsSummary(_ codes: [String]) -> some View {
        let joined = codes.joined(separator: ", ")
        return HStack(spacing: 8) {
            Image(systemName: "rectangle.stack.badge.plus")
                .foregroundStyle(.secondary)
            Text(joined)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cards added: \(joined)")
        .accessibilityIdentifier("liveGame.prompt.story.readCards")
    }

    private func amountAllocationPrompt(_ amountPrompt: BasicChoiceAmountPrompt) -> some View {
        let amounts = controller.amountDraft(for: presentation)
        let normalized = amountPrompt.normalizedAmounts(amounts)
        let total = amountPrompt.total(for: normalized)
        let submitEnabled = presentation.canSubmit && amountPrompt.isLegal(normalized)
        let disabledReason = amountPrompt.disabledReason(for: normalized, in: presentation)
        return VStack(alignment: .leading, spacing: 10) {
            Text(amountPrompt.legend)
                .font(.callout.weight(.semibold))
                .accessibilityIdentifier("liveGame.prompt.amount.legend")
            ForEach(Array(amountPrompt.visibleRows.enumerated()), id: \.element.id) { index, row in
                amountRow(row, index: index, amount: normalized[row.id] ?? 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(promptString("amountPrompt.total", value: "Total: %lld", Int64(total)))
                    .font(.footnote.monospacedDigit())
                    .accessibilityIdentifier("liveGame.prompt.amount.total")
                Text(amountPrompt.targetHint(in: presentation))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(submitEnabled ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("liveGame.prompt.amount.targetHint")
            }
            SemanticActionControl(
                accessibilityLabel: Text(promptString("amountPrompt.submit", value: "Submit")),
                semanticFocusID: BoardFocusID.promptAmountSubmit,
                onOutcome: { controller.handle(focusID: $0, $1) },
                label: {
                    HStack {
                        Text(promptString("amountPrompt.submit", value: "Submit"))
                        if presentation.actionPhase == .sending {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            )
            .buttonStyle(.borderedProminent)
            .focused(focusBinding, equals: BoardFocusID.promptAmountSubmit)
            .disabled(!submitEnabled)
            .accessibilityHint(
                disabledReason
                    ?? promptString(
                        "amountPrompt.submit.hint",
                        value: "Sends this allocation with version checking."
                    )
            )
            .accessibilityIdentifier("liveGame.prompt.amount.submit")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveGame.prompt.amount")
    }

    private func amountRow(
        _ row: BasicChoiceAmountPromptRow, index: Int, amount: Int
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body)
                Text(promptString(
                    "amountPrompt.row.bounds",
                    value: "Allowed %1$lld–%2$lld",
                    Int64(row.minBound), Int64(row.maxBound)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            amountControlButton(
                label: "−",
                accessibilityLabel: promptString(
                    "amountPrompt.decrease.accessibility",
                    value: "Decrease %@",
                    row.title
                ),
                focusID: BoardFocusID.promptAmountDecrease(index),
                disabled: !controller.adjustmentAvailable(rowID: row.id, delta: -1)
            )
            Text("\(amount)")
                .font(.headline.monospacedDigit())
                .frame(minWidth: 32)
                .accessibilityHidden(true)
            amountControlButton(
                label: "+",
                accessibilityLabel: promptString(
                    "amountPrompt.increase.accessibility",
                    value: "Increase %@",
                    row.title
                ),
                focusID: BoardFocusID.promptAmountIncrease(index),
                disabled: !controller.adjustmentAvailable(rowID: row.id, delta: 1)
            )
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(promptString(
            "amountPrompt.row.value",
            value: "%lld, allowed %lld to %lld",
            Int64(amount), Int64(row.minBound), Int64(row.maxBound)
        ))
        .accessibilityHint(promptString(
            "amountPrompt.row.hint",
            value: "Swipe up or down to adjust. Left and right controls also change this value."
        ))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                _ = controller.adjustAmount(rowID: row.id, delta: 1)
            case .decrement:
                _ = controller.adjustAmount(rowID: row.id, delta: -1)
            @unknown default:
                break
            }
        }
        .accessibilityIdentifier("liveGame.prompt.amount.row.\(index)")
    }

    private func amountControlButton(
        label: String,
        accessibilityLabel: String,
        focusID: SemanticFocusID,
        disabled: Bool
    ) -> some View {
        SemanticActionControl(
            accessibilityLabel: Text(accessibilityLabel),
            semanticFocusID: focusID,
            onOutcome: { controller.handle(focusID: $0, $1) },
            label: { Text(label).font(.headline.monospacedDigit()) }
        )
        .buttonStyle(.bordered)
        .focused(focusBinding, equals: focusID)
        .disabled(disabled || !presentation.canSubmit)
        .accessibilityIdentifier("liveGame.prompt.amount.control.\(focusID.rawValue)")
    }

    private func exchangeAmountPrompt(_ exchangePrompt: BasicChoiceExchangePrompt) -> some View {
        let amount = controller.exchangeAmount(for: presentation)
        let submitEnabled = presentation.canSubmit && exchangePrompt.isLegal(amount)
        return VStack(alignment: .leading, spacing: 10) {
            Text(promptString(
                "amountPrompt.exchange.legend",
                value: "Exchange %@",
                exchangePrompt.token
            ))
            .font(.callout.weight(.semibold))
            .accessibilityIdentifier("liveGame.prompt.exchange.legend")
            HStack(spacing: 12) {
                exchangeInvestigatorColumn(
                    name: exchangePrompt.fromDisplayName,
                    count: exchangePrompt.fromCount(for: amount)
                )
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        amountControlButton(
                            label: "←",
                            accessibilityLabel: promptString(
                                "amountPrompt.exchange.decrease.accessibility",
                                value: "Move one %@ back to %@",
                                exchangePrompt.token, exchangePrompt.fromDisplayName
                            ),
                            focusID: BoardFocusID.promptExchangeDecrease,
                            disabled: !exchangePrompt.canAdjust(amount: amount, delta: -1)
                        )
                        Text("\(abs(amount))")
                            .font(.headline.monospacedDigit())
                            .accessibilityHidden(true)
                        amountControlButton(
                            label: "→",
                            accessibilityLabel: promptString(
                                "amountPrompt.exchange.increase.accessibility",
                                value: "Move one %@ to %@",
                                exchangePrompt.token, exchangePrompt.toDisplayName
                            ),
                            focusID: BoardFocusID.promptExchangeIncrease,
                            disabled: !exchangePrompt.canAdjust(amount: amount, delta: 1)
                        )
                    }
                    Text(exchangeDirectionText(exchangePrompt, amount: amount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                exchangeInvestigatorColumn(
                    name: exchangePrompt.toDisplayName,
                    count: exchangePrompt.toCount(for: amount)
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(promptString(
                "amountPrompt.exchange.accessibility",
                value: "%1$@ has %2$lld. %3$@ has %4$lld.",
                exchangePrompt.fromDisplayName,
                Int64(exchangePrompt.fromCount(for: amount)),
                exchangePrompt.toDisplayName,
                Int64(exchangePrompt.toCount(for: amount))
            ))
            .accessibilityHint(promptString(
                "amountPrompt.exchange.hint",
                value: "Swipe up or down to move tokens between investigators."
            ))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    _ = controller.adjustExchangeAmount(delta: 1)
                case .decrement:
                    _ = controller.adjustExchangeAmount(delta: -1)
                @unknown default:
                    break
                }
            }
            SemanticActionControl(
                accessibilityLabel: Text(promptString("amountPrompt.exchange.submit", value: "Exchange")),
                semanticFocusID: BoardFocusID.promptExchangeSubmit,
                onOutcome: { controller.handle(focusID: $0, $1) },
                label: {
                    HStack {
                        Text(promptString("amountPrompt.exchange.submit", value: "Exchange"))
                        if presentation.actionPhase == .sending {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            )
            .buttonStyle(.borderedProminent)
            .focused(focusBinding, equals: BoardFocusID.promptExchangeSubmit)
            .disabled(!submitEnabled)
            .accessibilityHint(promptString(
                "amountPrompt.submit.hint",
                value: "Sends this allocation with version checking."
            ))
            .accessibilityIdentifier("liveGame.prompt.exchange.submit")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveGame.prompt.exchange")
    }

    private func exchangeInvestigatorColumn(name: String, count: Int) -> some View {
        VStack(spacing: 4) {
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text("\(count)")
                .font(.title3.monospacedDigit().weight(.bold))
        }
        .frame(maxWidth: .infinity)
    }

    private func exchangeDirectionText(
        _ exchangePrompt: BasicChoiceExchangePrompt, amount: Int
    ) -> String {
        if amount == 0 {
            return promptString("amountPrompt.exchange.none", value: "No tokens moved")
        }
        if amount > 0 {
            return promptString(
                "amountPrompt.exchange.forward",
                value: "%1$lld to %2$@",
                Int64(amount), exchangePrompt.toDisplayName
            )
        }
        return promptString(
            "amountPrompt.exchange.backward",
            value: "%1$lld to %2$@",
            Int64(abs(amount)), exchangePrompt.fromDisplayName
        )
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(presentation.choices) { choice in
                let focusID = BoardFocusID.promptChoice(choice.index)
                let resolved = presentation.resolvedChoiceLabel(
                    for: choice,
                    in: controller.projection
                )
                let title = resolved.title
                let isActionable = presentation.isChoiceActionable(
                    choice, in: controller.projection
                )
                SemanticActionControl(
                    accessibilityLabel: Text(resolved.accessibilityLabel),
                    semanticFocusID: focusID,
                    onOutcome: { controller.handle(focusID: $0, $1) },
                    label: {
                        HStack(spacing: 10) {
                            Image(systemName: resolved.systemImage)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                if let subtitle = resolved.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            let isSendingChoice = presentation.actionChoiceIndex == choice.index
                                && presentation.actionPhase == .sending
                            if isSendingChoice {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                )
                .buttonStyle(.bordered)
                .tint(choiceTint(for: choice))
                .focused(focusBinding, equals: focusID)
                .disabled(!isActionable || !presentation.canSubmit)
                // `SemanticActionControl` already applies `accessibilityLabel: Text(title)`
                // internally; an outer override here would risk silently diverging from it.
                .accessibilityHint(accessibilityHint(for: choice))
                .accessibilityIdentifier("liveGame.prompt.choice.\(choice.index)")
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.platformPromptBackground)
        } else {
            RoundedRectangle(cornerRadius: 18)
                .fill(.regularMaterial)
        }
    }

    /// A choice's semantic title, or its legacy raw fallback title when the semantic
    /// envelope is absent, resolved against the current authoritative board projection.
    private func displayTitle(for choice: BasicChoice) -> String {
        presentation.displayTitle(for: choice, in: controller.projection)
    }

    private func accessibilityHint(for choice: BasicChoice) -> String {
        presentation.accessibilityHint(for: choice, in: controller.projection)
    }

    private func choiceTint(for choice: BasicChoice) -> Color? {
        guard let descriptor = presentation.semanticPresentation?.descriptor(
            forSourceIndex: choice.index
        ) else { return nil }
        switch descriptor.kind {
        case .info:
            return .blue
        case .invalidLabel:
            return .secondary
        default:
            return nil
        }
    }
}

private func promptString(
    _ key: String,
    value: String,
    _ arguments: CVarArg...
) -> String {
    let format = Bundle.module.localizedString(forKey: key, value: value, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: Locale.current, arguments: arguments)
}

private extension Color {
    static var platformPromptBackground: Color {
        #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #elseif os(tvOS)
            Color.black.opacity(0.85)
        #else
            Color(uiColor: .systemBackground)
        #endif
    }
}
