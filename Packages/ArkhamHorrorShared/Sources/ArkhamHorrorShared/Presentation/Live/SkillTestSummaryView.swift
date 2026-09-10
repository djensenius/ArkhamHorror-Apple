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
                if let succeeded = summary.verdict?.succeeded ?? summary.result?.succeeded {
                    Divider()
                    Label(
                        verdictLabel(summary),
                        systemImage: succeeded
                            ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(succeeded ? .green : .red)
                    if let result = summary.result {
                        Text(resultBreakdown(result))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("liveGame.skillTest")
    }

    private func verdictLabel(_ summary: BoardSkillTestSummary) -> String {
        guard let verdict = summary.verdict else {
            return summary.result?.succeeded == true ? "Succeeded" : "Failed"
        }
        return verdict.displayLabel
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
