import SwiftUI

struct BasicChoicePromptView: View {
    let presentation: BasicChoicePromptPresentation
    let controller: BoardCommandController
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let isCompact: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var kind: BasicChoiceQuestionKind? {
        presentation.question.supportedQuestion?.kind
    }

    private var isStoryPrompt: Bool {
        kind == .read
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    isStoryPrompt ? "Story" : "Choose an action",
                    systemImage: isStoryPrompt ? "book.closed.fill" : "questionmark.circle.fill"
                )
                .font(.headline)
                Spacer()
                Text("Step \(presentation.questionVersion)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if presentation.question.supportedQuestion == nil {
                Label("Update required", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                if isStoryPrompt {
                    story
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
                if let title = content.flavorText.title {
                    Text(title)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("liveGame.prompt.story.title")
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(content.flavorText.body.enumerated()), id: \.offset) { _, entry in
                        FlavorTextEntryView(entry: entry)
                    }
                }
                .accessibilityIdentifier("liveGame.prompt.story.body")
                if let readCards = content.readCards, !readCards.isEmpty {
                    readCardsSummary(readCards)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("liveGame.prompt.story")
        }
    }

    private func readCardsSummary(_ codes: [CardCode]) -> some View {
        let joined = codes.map(\.rawValue).joined(separator: ", ")
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
            ForEach(presentation.choices) { choice in
                let focusID = BoardFocusID.promptChoice(choice.index)
                let title = displayTitle(for: choice)
                SemanticActionControl(
                    accessibilityLabel: Text(title),
                    semanticFocusID: focusID,
                    onOutcome: { controller.handle(focusID: $0, $1) },
                    label: {
                        HStack(spacing: 10) {
                            Image(systemName: choice.systemImage)
                                .frame(width: 22)
                            Text(title)
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
                .focused(focusBinding, equals: focusID)
                .disabled(!choice.isSupported || !presentation.canSubmit)
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

    /// A choice's display title, delegating to
    /// ``BoardDisplayFormatting/choiceDisplayTitle(for:in:)`` against the current
    /// authoritative board projection.
    private func displayTitle(for choice: BasicChoice) -> String {
        BoardDisplayFormatting.choiceDisplayTitle(for: choice, in: controller.projection)
    }

    private func accessibilityHint(for choice: BasicChoice) -> String {
        guard choice.isSupported else {
            return "This choice requires a newer app version."
        }
        if presentation.canSubmit {
            return "Activates choice \(choice.index + 1)."
        }
        return presentation.statusMessage ?? "This choice is currently read-only."
    }
}

/// Renders a single ``FlavorTextEntry``. `.i18n`'s `key` is a raw, un-translated i18n
/// lookup key (never narrative text on the wire); this app has no localization/lookup
/// infrastructure, so it is rendered literally in a monospaced, secondary style that
/// visually distinguishes it from resolved prose rather than presenting it as if it were
/// finished narrative text.
private struct FlavorTextEntryView: View {
    let entry: FlavorTextEntry

    var body: some View {
        switch entry {
        case let .basic(text):
            Text(text)
        case let .i18n(key, _):
            Text(key)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        case let .list(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    FlavorTextListItemView(item: item)
                }
            }
        }
    }
}

private struct FlavorTextListItemView: View {
    let item: FlavorTextListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                FlavorTextEntryView(entry: item.entry)
            }
            if !item.nested.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(item.nested.enumerated()), id: \.offset) { _, nested in
                        FlavorTextListItemView(item: nested)
                    }
                }
                .padding(.leading, 16)
            }
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
