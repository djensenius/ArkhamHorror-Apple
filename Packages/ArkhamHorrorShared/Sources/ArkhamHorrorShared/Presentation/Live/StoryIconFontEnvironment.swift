import SwiftUI

extension EnvironmentValues {
    @Entry var storyIconFontAvailability = WebIconFontAvailability()
    /// The inline text style ``ResolvedStoryEntryView`` gives catalog nodes, so icons and
    /// `[^N]` markers size to their enclosing text. A footnote body sets `.caption` for every
    /// entry nested in it; story text everywhere else keeps `.body`.
    @Entry var storyEntryInlineTextStyle: StoryInlineTextStyle = .body
}
