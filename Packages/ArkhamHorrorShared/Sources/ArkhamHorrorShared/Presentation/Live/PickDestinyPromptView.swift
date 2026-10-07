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

    let canSubmit: Bool
    let onSubmit: ([QuestionPresentation.DestinyDrawing]) -> Bool

    init(
        drawings: [QuestionPresentation.DestinyDrawing],
        canSubmit: Bool,
        onSubmit: @escaping ([QuestionPresentation.DestinyDrawing]) -> Bool
    ) {
        _drawings = State(initialValue: drawings)
        self.canSubmit = canSubmit
        self.onSubmit = onSubmit
    }

    private var requiredReversedCount: Int {
        (drawings.count + 1) / 2
    }

    private var reversedCount: Int {
        drawings.filter { $0.tarot.facing == .reversed }.count
    }

    private var hasRequiredReversedCount: Bool {
        reversedCount == requiredReversedCount
    }

    private var instructionText: String {
        "Reverse exactly \(requiredReversedCount) of \(drawings.count) cards, "
            + "then submit the reading."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Campaign reading")
                .font(.headline)
            Text(instructionText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(drawings.indices, id: \.self) { index in
                    drawingRow(index: index)
                }
            }
            Button {
                _ = onSubmit(drawings)
            } label: {
                Label("Done", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit || !hasRequiredReversedCount)
            .accessibilityIdentifier("liveGame.prompt.pickDestiny.done")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveGame.prompt.pickDestiny")
    }

    private func drawingRow(index: Int) -> some View {
        let drawing = drawings[index]
        return Button {
            toggleFacing(at: index)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: drawing.tarot.facing == .reversed
                    ? "arrow.uturn.down"
                    : "arrow.up")
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scenarioTitle(drawing.scenario))
                        .font(.callout.weight(.semibold))
                    Text("\(drawing.tarot.arcana) • \(drawing.tarot.facing.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.bordered)
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

    private func scenarioTitle(_ scenario: JSONValue) -> String {
        if case let .string(value) = scenario {
            return value
        }
        return scenario.kindDescription
    }
}
