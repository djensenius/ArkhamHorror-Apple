@testable import ArkhamHorrorShared
import SwiftUI
import Testing

@MainActor
@Suite("Story footnote caption metrics")
struct StoryFootnoteCaptionMetricsTests {
    @Test("Outside a footnote, headings and PlainText keep the body defaults")
    func bodyDefaultsAreUnchanged() {
        #expect(StoryBlockTextStyle.heading(level: 1, inheriting: .body)
            == StoryBlockTextStyle(font: .title2, inlineTextStyle: .title2))
        #expect(StoryBlockTextStyle.heading(level: 2, inheriting: .body)
            == StoryBlockTextStyle(font: .title3, inlineTextStyle: .title3))
        #expect(StoryBlockTextStyle.heading(level: 3, inheriting: .body)
            == StoryBlockTextStyle(font: .headline, inlineTextStyle: .headline))
        #expect(StoryBlockTextStyle.plainText(inheriting: .body)
            == StoryBlockTextStyle(font: .body, inlineTextStyle: .body))
        #expect(EnvironmentValues().storyEntryInlineTextStyle == .body)
    }

    @Test("Inside a footnote, a heading is caption semibold and PlainText is caption")
    func footnoteHeadingsAndPlainTextUseCaption() {
        let caption = StoryFootnoteEntryPresentation.textStyle
        #expect(caption == .caption)
        for level in 1 ... 3 {
            #expect(StoryBlockTextStyle.heading(level: level, inheriting: caption)
                == StoryBlockTextStyle(
                    font: .system(.caption, weight: .semibold), inlineTextStyle: .caption
                ))
        }
        #expect(StoryBlockTextStyle.plainText(inheriting: caption)
            == StoryBlockTextStyle(font: .system(.caption), inlineTextStyle: .caption))
    }

    /// Renders the footnote's own note body and the same entry outside a footnote. The note
    /// body must be narrower: its `[^N]` markers (sized from the `inlineTextStyle` argument
    /// `ResolvedStoryEntryView` passes on), its heading and its PlainText all follow the
    /// caption `storyEntryInlineTextStyle` the footnote sets.
    @Test(
        "The footnote body renders markers, headings and PlainText at caption size",
        arguments: [
            ("markers", ResolvedStoryEntry.nodes(
                Array(repeating: .footnoteMarker("8"), count: 24)
            )),
            ("heading", .heading(level: .level1, nodes: [.text("The Essex County Express")])),
            ("plainText", .modified(
                modifiers: [.plainText], entry: .text("Seal the gate before the dawn breaks")
            )),
        ]
    )
    func footnoteBodyRendersAtCaptionSize(label: String, entry: ResolvedStoryEntry) throws {
        let inside = try renderedWidth(StoryFootnoteEntryView.noteBody(
            entry: entry, cardCatalog: nil
        ))
        let outside = try renderedWidth(ResolvedStoryEntryView(entry: entry, cardCatalog: nil))
        #expect(inside > 0, "\(label)")
        #expect(inside < outside * 0.9, "\(label): \(inside) vs \(outside)")
    }

    @Test("A footnote containing a table speaks its headers, then each row")
    func footnoteTableSpeaksHeadersAndCells() {
        func row(_ cells: [String], header: Bool = false) -> StoryTableRow {
            StoryTableRow(cells: cells.map {
                StoryTableCell(isHeader: header, children: [.text($0)])
            })
        }
        let body: ResolvedStoryEntry = .nodes([
            .paragraph([.text("Record the result:")]),
            .table(
                head: [row(["Path", "Cost"], header: true)],
                body: [
                    row(["Woods", "2"]),
                    StoryTableRow(cells: [
                        StoryTableCell(isHeader: false, children: [.text("River")]),
                        StoryTableCell(
                            isHeader: false,
                            children: [.emphasis(.bold, [.text("1")]), .footnoteMarker("3")]
                        ),
                    ]),
                ]
            ),
            .text("Then continue."),
        ])
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("en") {
            #expect(StoryFootnoteEntryPresentation(
                number: 4, entry: body, dynamicTypeSize: .large
            ).accessibilityLabel
                == "Footnote 4: Record the result: Path, Cost. Woods, 2. River, 1 footnote 3 "
                + "Then continue.")
        }
    }

    @Test("A prose footnote speaks exactly as before")
    func proseFootnoteSpokenTextIsUnchanged() {
        // The Dunwich Legacy prologue footnote 2 as the catalog resolves it.
        let note: [StoryNode] = [
            .text("Translated as "),
            .emphasis(.italic, [.text("DH"), .footnoteMarker("4")]),
            .text("."),
        ]
        #expect(StoryFootnoteEntryPresentation.spokenText(for: note)
            == StoryNodePresentation.accessibilityLabel(for: note))
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("en") {
            #expect(StoryFootnoteEntryPresentation(
                number: 2, entry: .nodes(note), dynamicTypeSize: .large
            ).accessibilityLabel == "Footnote 2: Translated as DH footnote 4.")
        }
    }

    private func renderedWidth(_ view: some View) throws -> CGFloat {
        let renderer = ImageRenderer(content: view.fixedSize())
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return CGFloat(image.width)
    }
}
