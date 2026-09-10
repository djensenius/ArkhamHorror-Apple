import SwiftUI

struct SkillTestSummaryView: View {
    let projection: BoardSkillTestProjection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Skill Test", systemImage: "die.face.5.fill")
                .font(.headline)
            switch projection {
            case .unavailable:
                Label(
                    "Skill-test details require an app update.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            case let .available(summary):
                Text(summary.step.displayTitle)
                    .font(.subheadline.weight(.semibold))
                Text(
                    "Current skill \(summary.modifiedSkillValue) vs difficulty "
                        + "\(summary.modifiedDifficulty)"
                )
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                if let result = summary.result {
                    Divider()
                    Label(
                        result.succeeded ? "Succeeded" : "Failed",
                        systemImage: result.succeeded
                            ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(result.succeeded ? .green : .red)
                    Text(resultBreakdown(result))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("liveGame.skillTest")
    }

    private func resultBreakdown(_ result: BoardSkillTestResult) -> String {
        var text = "Skill \(result.skillValue), icons \(result.iconValue), chaos "
            + "\(result.chaosTokensValue), difficulty \(result.difficulty)"
        if let modifiers = result.resultModifiers {
            text += ", result modifier \(modifiers)"
        }
        return text
    }
}
