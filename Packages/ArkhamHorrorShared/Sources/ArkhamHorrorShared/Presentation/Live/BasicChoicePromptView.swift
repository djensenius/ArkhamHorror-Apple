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
                        .accessibilityLabel(presentation.questionHintAccessibilityLabel() ?? hint)
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

    private var choices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(regularChoices) { choice in
                choiceButton(for: choice, isFinishingAction: false)
            }
            if !finishingChoices.isEmpty {
                Divider()
                ForEach(finishingChoices) { choice in
                    choiceButton(for: choice, isFinishingAction: true)
                }
            }
        }
    }

    private var regularChoices: [BasicChoice] {
        presentation.displayOrderedChoices().filter {
            !presentation.isCompletingSelection($0)
        }
    }

    private var finishingChoices: [BasicChoice] {
        presentation.displayOrderedChoices().filter {
            presentation.isCompletingSelection($0)
        }
    }

    @ViewBuilder
    private func choiceButton(
        for choice: BasicChoice,
        isFinishingAction: Bool
    ) -> some View {
        if isFinishingAction {
            choiceControl(for: choice)
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
        } else {
            choiceControl(for: choice)
                .buttonStyle(.bordered)
                .tint(choiceTint(for: choice))
        }
    }

    private func choiceControl(for choice: BasicChoice) -> some View {
        let focusID = BoardFocusID.promptChoice(choice.index)
        let resolved = presentation.resolvedChoiceLabel(
            for: choice,
            in: controller.projection
        )
        let title = resolved.title
        let isActionable = presentation.isChoiceActionable(
            choice, in: controller.projection
        )
        return SemanticActionControl(
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
        .focused(focusBinding, equals: focusID)
        .disabled(!isActionable || !presentation.canSubmit)
        // `SemanticActionControl` already applies `accessibilityLabel: Text(title)`
        // internally; an outer override here would risk silently diverging from it.
        .accessibilityHint(accessibilityHint(for: choice))
        .accessibilityIdentifier("liveGame.prompt.choice.\(choice.index)")
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
