import Foundation

/// Inline nodes and the spoken form of a prompt string carrying a `[^N]` footnote marker,
/// so the marker renders like story text and VoiceOver reads "footnote N" (TASK-1.22.12).
struct BasicChoiceFootnotedText: Sendable, Equatable {
    let nodes: [StoryNode]
    let accessibilityLabel: String
}

extension BasicChoicePromptPresentation {
    /// The question-label header (`headerTitle`) as nodes and spoken text, or `nil` when the
    /// header does not come from the question label or carries no footnote marker.
    ///
    /// The web renders this header with mustache, so a raw label shows a literal `[^N]`;
    /// natively the reference renders as a marker, as it does in story text.
    var promptQuestionLabelFootnote: BasicChoiceFootnotedText? {
        guard semanticPresentation != nil else { return nil }
        if let resolution = promptLabelResolutions["questionLabel"], resolution.title != nil {
            guard let nodes = resolution.inlineNodes,
                  StoryFootnoteSuperscript.title(for: nodes) != nil
            else { return nil }
            return BasicChoiceFootnotedText(
                nodes: nodes,
                accessibilityLabel: resolution.accessibilityTitle
                    ?? nodes.map(\.spokenText).joined()
            )
        }
        guard let title = promptQuestionLabelTitle else { return nil }
        let nodes = StoryNode.splittingFootnoteMarkers(in: title)
        guard StoryFootnoteSuperscript.title(for: nodes) != nil else { return nil }
        return BasicChoiceFootnotedText(
            nodes: nodes,
            accessibilityLabel: nodes.map(\.spokenText).joined()
        )
    }
}
