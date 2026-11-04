@testable import ArkhamHorrorShared
import SwiftUI
import Testing

@Suite("Story web glyph font metrics")
struct StoryWebGlyphFontMetricsTests {
    @Test("Web glyph sizing follows the text context and web elder sign scale")
    func webGlyphSizingFollowsTextContext() {
        let body = StoryWebGlyphFontMetrics.platformPreferredPointSize(for: .body)
        let headline = StoryWebGlyphFontMetrics.platformPreferredPointSize(for: .headline)
        let caption = StoryWebGlyphFontMetrics.platformPreferredPointSize(for: .caption)

        #expect(
            StoryWebGlyphFontMetrics.pointSize(forIconNamed: "willpower", textStyle: .body)
                == body
        )
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

    @Test("Web glyph base sizing ignores the current Dynamic Type category")
    func baseSizingIgnoresCurrentDynamicTypeCategory() {
        for textStyle in StoryInlineTextStyle.allCases {
            #expect(
                StoryWebGlyphFontMetrics.platformPreferredPointSize(
                    for: textStyle,
                    currentContentSizeCategory: .accessibilityExtraExtraExtraLarge
                ) == StoryWebGlyphFontMetrics.platformPreferredPointSize(
                    for: textStyle,
                    currentContentSizeCategory: .large
                )
            )
        }
    }

    @Test("Footnote markers scale with Dynamic Type and the enclosing text style")
    func footnoteMarkerScalesWithDynamicTypeAndEnclosingStyle() {
        func expected(_ number: String, parent: CGFloat) -> StoryFootnoteMarkerRun {
            StoryFootnoteMarkerRun(
                number: number, pointSize: parent * 0.7, baselineOffset: parent * (1.0 / 3.0)
            )
        }
        // An injected size table proves the run follows both the style and the size.
        let table: (StoryInlineTextStyle, DynamicTypeSize) -> CGFloat = { style, size in
            let base: CGFloat = style == .caption ? 12 : 17
            return size == .accessibility5 ? base * 3 : base
        }
        #expect(
            StoryFootnoteMarkerMetrics.run(
                "1", textStyle: .body, dynamicTypeSize: .large, parentPointSize: table
            ) == expected("1", parent: 17)
        )
        #expect(
            StoryFootnoteMarkerMetrics.run(
                "1", textStyle: .body, dynamicTypeSize: .accessibility5, parentPointSize: table
            ) == expected("1", parent: 51)
        )
        // A `small` span renders its children with `.caption`, so the marker shrinks too.
        let smallSpan = StoryInlineTextStyle.body.applying(emphasis: .small)
        #expect(smallSpan == .caption)
        #expect(
            StoryFootnoteMarkerMetrics.run(
                "2", textStyle: smallSpan, dynamicTypeSize: .large, parentPointSize: table
            ) == expected("2", parent: 12)
        )

        // The platform sizes: at `.large` they match the preferred size; a caption marker is
        // smaller than a body marker; Dynamic Type grows them where the platform has it.
        for style in StoryInlineTextStyle.allCases {
            let preferred = StoryWebGlyphFontMetrics.platformPreferredPointSize(for: style)
            let run = StoryFootnoteMarkerMetrics.run("3", textStyle: style, dynamicTypeSize: .large)
            #expect(abs(run.pointSize - preferred * 0.7) < 0.0001)
            #expect(abs(run.baselineOffset - preferred / 3) < 0.0001)
        }
        let body = StoryFootnoteMarkerMetrics.run("4", textStyle: .body, dynamicTypeSize: .large)
        let caption = StoryFootnoteMarkerMetrics.run(
            "4", textStyle: .caption, dynamicTypeSize: .large
        )
        #expect(caption.pointSize < body.pointSize)
        let largest = StoryFootnoteMarkerMetrics.run(
            "4", textStyle: .body, dynamicTypeSize: .accessibility5
        )
        #if os(macOS)
            // macOS has no Dynamic Type; SwiftUI text styles keep their size there too.
            #expect(largest == body)
        #else
            #expect(largest.pointSize > body.pointSize)
            #expect(largest.baselineOffset > body.baselineOffset)
        #endif
    }
}
