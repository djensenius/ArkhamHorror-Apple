import SwiftUI

extension BasicChoicePromptPresentation {
    var pickDestinyDrawings: [QuestionPresentation.DestinyDrawing]? {
        guard semanticPresentation?.presentation.questionKind == .pickDestiny,
              let drawings = semanticPresentation?.presentation.drawings,
              !drawings.isEmpty
        else { return nil }
        return drawings
    }
}

struct PickDestinyPromptView: View {
    @State private var drawings: [QuestionPresentation.DestinyDrawing]

    private let prompt: PickDestinyPromptPresentation
    private let canSubmit: Bool
    private let onSubmit: ([QuestionPresentation.DestinyDrawing]) -> Bool

    init(
        prompt: PickDestinyPromptPresentation,
        canSubmit: Bool,
        onSubmit: @escaping ([QuestionPresentation.DestinyDrawing]) -> Bool
    ) {
        _drawings = State(initialValue: prompt.drawings)
        self.prompt = prompt
        self.canSubmit = canSubmit
        self.onSubmit = onSubmit
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
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(drawings.indices, id: \.self) { index in
                    drawingRow(index: index)
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
            Button {
                _ = onSubmit(drawings)
            } label: {
                Label(prompt.doneLabel, systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isSubmitEnabled)
            .accessibilityLabel(prompt.doneLabel)
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

    private func drawingRow(index: Int) -> some View {
        let drawing = drawings[index]
        let row = prompt.rows[index]
        return Button {
            toggleFacing(at: index)
        } label: {
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
        .buttonStyle(.bordered)
        .accessibilityLabel("\(row.scenarioTitle), \(row.tarotTitle)")
        .accessibilityValue(localizedFacing(drawing.tarot.facing))
        .accessibilityHint(pickDestinyLocalized(
            "pickDestiny.row.flip.hint",
            "Activating flips this tarot card."
        ))
        .accessibilityIdentifier("liveGame.prompt.pickDestiny.row.\(index)")
    }

    private func toggleFacing(at index: Int) {
        let drawing = drawings[index]
        let nextFacing: QuestionPresentation.TarotCard.Facing = drawing.tarot.facing == .upright
            ? .reversed
            : .upright
        drawings[index] = QuestionPresentation.DestinyDrawing(
            scenario: drawing.scenario,
            tarot: QuestionPresentation.TarotCard(
                facing: nextFacing,
                arcana: drawing.tarot.arcana
            )
        )
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
