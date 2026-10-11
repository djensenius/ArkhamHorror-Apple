@testable import ArkhamHorrorShared
import Testing

@Suite("Story web glyph font metrics")
struct StoryWebGlyphFontMetricsTests {
    @Test("Web glyph sizing follows the text context and web elder sign scale")
    func webGlyphSizingFollowsTextContext() {
        let body = StoryWebGlyphFontMetrics.platformPreferredPointSize(for: .body)
        let headline = StoryWebGlyphFontMetrics.platformPreferredPointSize(for: .headline)
        let caption = StoryWebGlyphFontMetrics.platformPreferredPointSize(for: .caption)

        #expect(StoryWebGlyphFontMetrics.pointSize(forIconNamed: "willpower", textStyle: .body) == body)
        #expect(
            StoryWebGlyphFontMetrics.pointSize(forIconNamed: "willpower", textStyle: .headline)
                == headline
        )
        #expect(
            StoryWebGlyphFontMetrics.pointSize(forIconNamed: "willpower", textStyle: .caption)
                == caption
        )
        #expect(
            abs(StoryWebGlyphFontMetrics.pointSize(forIconNamed: "elderSign", textStyle: .body)
                - body * 1.3) < 0.0001
        )
        #expect(
            abs(StoryWebGlyphFontMetrics.pointSize(forIconNamed: "autoFail", textStyle: .headline)
                - headline * 1.3) < 0.0001
        )
    }
}
