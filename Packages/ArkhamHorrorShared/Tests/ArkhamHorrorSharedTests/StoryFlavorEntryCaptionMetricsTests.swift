@testable import ArkhamHorrorShared
import SwiftUI
import Testing

@MainActor
@Suite("Story flavor entry caption metrics")
struct StoryFlavorEntryCaptionMetricsTests {
    private let caption = StoryFootnoteEntryPresentation.textStyle

    @Test(
        "Inside a footnote, checkpoint and resolution entries are caption semibold",
        arguments: [
            [FlavorTextModifier.checkpointEntry],
            [.resolutionEntry],
            [.checkpointEntry, .resolutionEntry],
            [.redEntry, .checkpointEntry],
            [.resolutionEntry, .centeredEntry],
        ]
    )
    func footnoteEntriesUseCaptionSemibold(modifiers: [FlavorTextModifier]) {
        #expect(caption == .caption)
        let font = StoryFlavorTextModifier.font(for: modifiers, inheriting: caption)
        #expect(font == .system(.caption, weight: .semibold), "\(modifiers)")
        #expect(font != .headline, "\(modifiers)")
        #expect(StoryBlockTextStyle.emphasizedEntry(inheriting: caption)
            == StoryBlockTextStyle(
                font: .system(.caption, weight: .semibold), inlineTextStyle: .caption
            ))
    }

    @Test(
        "Outside a footnote, checkpoint and resolution entries stay headline",
        arguments: [
            [FlavorTextModifier.checkpointEntry],
            [.resolutionEntry],
            [.checkpointEntry, .resolutionEntry],
            [.redEntry, .checkpointEntry],
            [.resolutionEntry, .centeredEntry],
        ]
    )
    func bodyEntriesStayHeadline(modifiers: [FlavorTextModifier]) {
        #expect(EnvironmentValues().storyEntryInlineTextStyle == .body)
        #expect(StoryFlavorTextModifier.font(for: modifiers, inheriting: .body) == .headline)
        #expect(StoryBlockTextStyle.emphasizedEntry(inheriting: .body)
            == StoryBlockTextStyle(font: .headline, inlineTextStyle: .headline))
    }

    @Test("PlainText takes precedence over checkpoint and resolution")
    func plainTextTakesPrecedence() {
        for modifiers: [FlavorTextModifier] in [
            [.plainText, .checkpointEntry], [.resolutionEntry, .plainText], [.plainText],
        ] {
            #expect(StoryFlavorTextModifier.font(for: modifiers, inheriting: .body) == .body)
            #expect(StoryFlavorTextModifier.font(for: modifiers, inheriting: caption)
                == .system(.caption))
        }
    }

    @Test("Entries without PlainText, checkpoint or resolution set no font")
    func otherModifiersSetNoFont() {
        let others = FlavorTextModifier.allCases.filter {
            ![.plainText, .checkpointEntry, .resolutionEntry].contains($0)
        }
        #expect(others.count == FlavorTextModifier.allCases.count - 3)
        for inherited in [StoryInlineTextStyle.body, caption] {
            #expect(StoryFlavorTextModifier.font(for: [], inheriting: inherited) == nil)
            #expect(StoryFlavorTextModifier.font(for: others, inheriting: inherited) == nil)
            for modifier in others {
                let font = StoryFlavorTextModifier.font(for: [modifier], inheriting: inherited)
                #expect(font == nil, "\(modifier)")
            }
        }
    }
}
