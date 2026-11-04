import SwiftUI

/// A prompt string that renders a `[^N]` footnote as a marker, like story text, and reads
/// "footnote N" (TASK-1.22.12). Without a footnote it is exactly `Text(text)`.
struct FootnotedInlineText: View {
    let text: String
    let footnote: BasicChoiceFootnotedText?
    var textStyle: StoryInlineTextStyle = .body
    var suffix = ""

    var body: some View {
        if let footnote {
            StoryInlineTextLabel(
                fallbackText: text + suffix,
                nodes: footnote.nodes + (suffix.isEmpty ? [] : [.text(suffix)]),
                textStyle: textStyle
            )
            .accessibilityLabel(Text(verbatim: footnote.accessibilityLabel + suffix))
        } else {
            Text(text + suffix)
        }
    }
}

/// A `Label` whose title may carry a `[^N]` footnote; without one it is exactly
/// `Label(text, systemImage:)`.
struct FootnotedInlineLabel: View {
    let text: String
    let footnote: BasicChoiceFootnotedText?
    let systemImage: String
    var textStyle: StoryInlineTextStyle = .body

    var body: some View {
        if let footnote {
            Label {
                FootnotedInlineText(text: text, footnote: footnote, textStyle: textStyle)
            } icon: {
                Image(systemName: systemImage)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: footnote.accessibilityLabel))
        } else {
            Label(text, systemImage: systemImage)
        }
    }
}
