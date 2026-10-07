import SwiftUI

struct PickDestinyPromptView: View {
    private let prompt: PickDestinyPromptPresentation
    private let drawings: [QuestionPresentation.DestinyDrawing]
    private let canSubmit: Bool
    private let controller: BoardCommandController
    private let focusBinding: FocusState<SemanticFocusID?>.Binding
    private let isCompact: Bool

    init(
        prompt: PickDestinyPromptPresentation,
        drawings: [QuestionPresentation.DestinyDrawing],
        canSubmit: Bool,
        controller: BoardCommandController,
        focusBinding: FocusState<SemanticFocusID?>.Binding,
        isCompact: Bool
    ) {
        self.prompt = prompt
        self.drawings = drawings
        self.canSubmit = canSubmit
        self.controller = controller
        self.focusBinding = focusBinding
        self.isCompact = isCompact
    }

    private var requiredReversedCount: Int {
        PickDestinySelectionRules.requiredReversedCount(for: drawings.count)
    }

    private var reversedCount: Int {
        PickDestinySelectionRules.reversedCount(in: drawings)
    }

    private var hasRequiredReversedCount: Bool {
        PickDestinySelectionRules.hasRequiredReversedCount(drawings)
    }

    private var isSubmitEnabled: Bool {
        canSubmit && hasRequiredReversedCount
    }

    private var cardListMaxHeight: CGFloat {
        isCompact ? 240 : 420
    }

    private var progressText: String {
        pickDestinyLocalized(
            "pickDestiny.progress",
            "%1$lld of %2$lld reversed",
            Int64(reversedCount),
            Int64(drawings.count)
        )
    }

    private var disabledHint: String? {
        guard !isSubmitEnabled else { return nil }
        if !canSubmit {
            return pickDestinyLocalized(
                "pickDestiny.submit.disabled.readOnly",
                "This reading cannot be submitted right now."
            )
        }
        return pickDestinyLocalized(
            "pickDestiny.submit.disabled.count",
            "Reverse exactly %1$lld of %2$lld cards before submitting. %3$lld of %4$lld reversed.",
            Int64(requiredReversedCount),
            Int64(drawings.count),
            Int64(reversedCount),
            Int64(drawings.count)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.title)
                .font(.headline)
            Text(prompt.instructions)
                .font(.footnote)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(drawings.indices, id: \.self) { index in
                            drawingRow(index: index)
                                .id(BoardFocusID.promptPickDestinyRow(index))
                        }
                    }
                }
                .frame(maxHeight: cardListMaxHeight)
                .accessibilityIdentifier("liveGame.prompt.pickDestiny.cards")
                .onAppear {
                    scrollToFocusedRow(focusBinding.wrappedValue, proxy: proxy)
                }
                .onChange(of: focusBinding.wrappedValue) { _, newValue in
                    scrollToFocusedRow(newValue, proxy: proxy)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(progressText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(hasRequiredReversedCount ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("liveGame.prompt.pickDestiny.progress")
                if let disabledHint {
                    Text(disabledHint)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("liveGame.prompt.pickDestiny.disabledReason")
                }
            }
            SemanticActionControl(
                accessibilityLabel: Text(prompt.doneLabel),
                semanticFocusID: BoardFocusID.promptPickDestinySubmit,
                onOutcome: { controller.handle(focusID: $0, $1) },
                label: {
                    Label(prompt.doneLabel, systemImage: "checkmark.circle.fill")
                }
            )
            .buttonStyle(.borderedProminent)
            .focused(focusBinding, equals: BoardFocusID.promptPickDestinySubmit)
            .disabled(!isSubmitEnabled)
            .accessibilityValue(progressText)
            .accessibilityHint(disabledHint ?? pickDestinyLocalized(
                "pickDestiny.submit.hint",
                "Submits this tarot reading."
            ))
            .accessibilityIdentifier("liveGame.prompt.pickDestiny.done")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveGame.prompt.pickDestiny")
    }

    private func scrollToFocusedRow(
        _ focusedID: SemanticFocusID?,
        proxy: ScrollViewProxy
    ) {
        guard let focusedID,
              drawings.indices.contains(where: {
                  BoardFocusID.promptPickDestinyRow($0) == focusedID
              })
        else { return }
        withAnimation {
            proxy.scrollTo(focusedID, anchor: .center)
        }
    }

    private func drawingRow(index: Int) -> some View {
        let drawing = drawings[index]
        let row = prompt.rows[index]
        let focusID = BoardFocusID.promptPickDestinyRow(index)
        return SemanticActionControl(
            accessibilityLabel: Text("\(row.scenarioTitle), \(row.tarotTitle)"),
            semanticFocusID: focusID,
            onOutcome: { controller.handle(focusID: $0, $1) },
            label: {
                HStack(spacing: 10) {
                    Image(systemName: drawing.tarot.facing == .reversed
                        ? "arrow.uturn.down"
                        : "arrow.up")
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.scenarioTitle)
                            .font(.callout.weight(.semibold))
                        Text("\(row.tarotTitle) • \(localizedFacing(drawing.tarot.facing))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        )
        .buttonStyle(.bordered)
        .focused(focusBinding, equals: focusID)
        .disabled(!canSubmit)
        .accessibilityValue(localizedFacing(drawing.tarot.facing))
        .accessibilityHint(pickDestinyLocalized(
            "pickDestiny.row.flip.hint",
            "Activating flips this tarot card."
        ))
        .accessibilityIdentifier("liveGame.prompt.pickDestiny.row.\(index)")
    }

    private func localizedFacing(_ facing: QuestionPresentation.TarotCard.Facing) -> String {
        switch facing {
        case .upright:
            pickDestinyLocalized("pickDestiny.facing.upright", "Upright")
        case .reversed:
            pickDestinyLocalized("pickDestiny.facing.reversed", "Reversed")
        }
    }
}

func pickDestinyLocalized(
    _ key: String,
    _ fallback: String,
    _ arguments: CVarArg...
) -> String {
    let format = NSLocalizedString(key, bundle: .module, value: fallback, comment: "")
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: Locale.current, arguments: arguments)
}
