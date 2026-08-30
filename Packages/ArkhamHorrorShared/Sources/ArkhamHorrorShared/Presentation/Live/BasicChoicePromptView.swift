import SwiftUI

struct BasicChoicePromptView: View {
    let presentation: BasicChoicePromptPresentation
    let controller: BoardCommandController
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let isCompact: Bool
    let onRetry: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Choose an action", systemImage: "questionmark.circle.fill")
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
                choices
            }

            if let message = presentation.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("liveGame.prompt.status")
            }

            if presentation.canRetry {
                Button("Retry choice", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Sends the same choice again with version checking.")
                    .accessibilityIdentifier("liveGame.prompt.retry")
            }
        }
        .padding(isCompact ? 14 : 18)
        .frame(maxWidth: isCompact ? .infinity : 360, alignment: .leading)
        .background(background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active choice prompt")
        .accessibilityIdentifier("liveGame.prompt")
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(presentation.choices) { choice in
                Button {
                    controller.activatePromptChoice(choice.index)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: choice.systemImage)
                            .frame(width: 22)
                        Text(choice.title)
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
                .buttonStyle(.bordered)
                .focused(focusBinding, equals: BoardFocusID.promptChoice(choice.index))
                .disabled(!choice.isSupported || !presentation.canSubmit)
                .accessibilityLabel(choice.title)
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
