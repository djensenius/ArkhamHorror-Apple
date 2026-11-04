import Foundation

/// Inline nodes and the spoken form of a prompt string carrying a `[^N]` footnote marker,
/// so the marker renders like story text and VoiceOver reads "footnote N" (TASK-1.22.12).
struct BasicChoiceFootnotedText: Sendable, Equatable {
    let nodes: [StoryNode]
    let accessibilityLabel: String
}

extension BasicChoiceFootnotedText {
    /// A resolved catalog label whose inline nodes carry a `[^N]` footnote marker; `nil`
    /// for unresolved labels and labels without a footnote.
    init?(resolution: BasicChoiceLabelResolution?) {
        guard resolution?.title != nil, let nodes = resolution?.inlineNodes,
              StoryFootnoteSuperscript.title(for: nodes) != nil
        else { return nil }
        self.init(
            nodes: nodes,
            accessibilityLabel: resolution?.accessibilityTitle ?? Self.spokenText(nodes)
        )
    }

    /// A raw label carrying a `[^N]` footnote reference, split into text and markers.
    init?(rawText: String) {
        let nodes = StoryNode.splittingFootnoteMarkers(in: rawText)
        guard StoryFootnoteSuperscript.title(for: nodes) != nil else { return nil }
        self.init(nodes: nodes, accessibilityLabel: Self.spokenText(nodes))
    }

    /// The nodes' spoken form, trimmed like the resolver's and choice labels' spoken titles,
    /// so a marker-only label reads "footnote N" without a leading space.
    private static func spokenText(_ nodes: [StoryNode]) -> String {
        nodes.map(\.spokenText).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension BasicChoicePromptPresentation {
    /// The question-label header (`headerTitle`) as nodes and spoken text, or `nil` when the
    /// header does not come from the question label or carries no footnote marker.
    ///
    /// The web renders this header with mustache, so a raw label shows a literal `[^N]`;
    /// natively the reference renders as a marker, as it does in story text.
    var promptQuestionLabelFootnote: BasicChoiceFootnotedText? {
        guard let presentation = semanticPresentation?.presentation else { return nil }
        return promptLabelFootnote(
            key: "questionLabel", labelText: presentation.questionLabel?.text
        )
    }

    /// The footnoted form of a prompt label shown as its resolved catalog title or, for a
    /// raw (non-`$`) label, its trimmed text; `nil` for fallbacks and footnote-free labels.
    func promptLabelFootnote(key: String, labelText: String?) -> BasicChoiceFootnotedText? {
        if let resolution = promptLabelResolutions[key], resolution.title != nil {
            return BasicChoiceFootnotedText(resolution: resolution)
        }
        guard let labelText, !labelText.hasPrefix("$") else { return nil }
        let trimmed = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : BasicChoiceFootnotedText(rawText: trimmed)
    }
}
