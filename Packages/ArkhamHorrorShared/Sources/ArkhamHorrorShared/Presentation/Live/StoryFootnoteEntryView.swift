import SwiftUI

/// The web's `div.footnote` (`FormattedEntry.vue:102-108`, `:130-154`): a bold raised note
/// number beside a smaller, dimmed note body, read by VoiceOver as one element.
struct StoryFootnoteEntryPresentation: Equatable {
    /// `font-size: 0.8em` of the story body.
    static let textStyle: StoryInlineTextStyle = .caption
    /// `gap: 0.4em`.
    static let spacing: CGFloat = 5
    /// `margin-top: 0.35em`.
    static let topPadding: CGFloat = 4

    let marker: StoryFootnoteMarkerRun
    let accessibilityLabel: String

    init(
        number: Int,
        entry: ResolvedStoryEntry,
        cardCatalog: CardCatalogSnapshot? = nil,
        dynamicTypeSize: DynamicTypeSize,
        parentPointSize: (StoryInlineTextStyle, DynamicTypeSize) -> CGFloat
            = StoryWebGlyphFontMetrics.scaledPointSize
    ) {
        marker = StoryFootnoteMarkerMetrics.run(
            String(number),
            textStyle: Self.textStyle,
            dynamicTypeSize: dynamicTypeSize,
            parentPointSize: parentPointSize
        )
        accessibilityLabel = Self.accessibilityLabel(
            number: number,
            body: Self.spokenText(for: entry, cardCatalog: cardCatalog)
        )
    }

    /// "Footnote N: body", localized.
    static func accessibilityLabel(number: Int, body: String) -> String {
        String(
            format: CampaignPromptLocalization.localized(
                "story.footnote.accessibilityLabel", "Footnote %d: %@"
            ),
            number,
            body
        )
    }

    // The VoiceOver text of a resolved note body, matching what `ResolvedStoryEntryView`
    // shows for each entry.
    // swiftlint:disable:next cyclomatic_complexity
    static func spokenText(
        for entry: ResolvedStoryEntry, cardCatalog: CardCatalogSnapshot?
    ) -> String {
        func joined(_ parts: [String]) -> String {
            parts.filter { !$0.isEmpty }.joined(separator: " ")
        }
        func spokenEntries(_ entries: [ResolvedStoryEntry]) -> String {
            joined(entries.map { spokenText(for: $0, cardCatalog: cardCatalog) })
        }
        func spokenItems(_ items: [ResolvedStoryListItem]) -> String {
            joined(items.map { item in
                joined([
                    spokenText(for: item.entry, cardCatalog: cardCatalog),
                    spokenItems(item.nested),
                ])
            })
        }
        let text: String = switch entry {
        case let .text(value):
            value
        case let .nodes(nodes), let .heading(_, nodes):
            StoryNodePresentation.accessibilityLabel(for: nodes)
        case let .modified(_, entry):
            spokenText(for: entry, cardCatalog: cardCatalog)
        case let .composite(entries), let .columns(entries):
            spokenEntries(entries)
        case let .list(items):
            spokenItems(items)
        case let .cardReference(cardCode, _):
            cardCatalog?.displayName(for: cardCode) ?? "Card \(cardCode.rawValue)"
        case let .tarotReference(arcana):
            "Tarot \(arcana)"
        case let .chaosTokenReference(face):
            "Chaos token \(face.rawValue)"
        case let .chaosTokenMorph(from, target):
            "Chaos token \(from.rawValue) to \(target.rawValue)"
        case .divider:
            ""
        case let .footnote(number, entry):
            accessibilityLabel(
                number: number, body: spokenText(for: entry, cardCatalog: cardCatalog)
            )
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A ``ResolvedStoryEntry/footnote(number:entry:)`` in body order where the server placed it.
struct StoryFootnoteEntryView: View {
    let number: Int
    let entry: ResolvedStoryEntry
    var cardCatalog: CardCatalogSnapshot?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let presentation = StoryFootnoteEntryPresentation(
            number: number,
            entry: entry,
            cardCatalog: cardCatalog,
            dynamicTypeSize: dynamicTypeSize
        )
        HStack(alignment: .firstTextBaseline, spacing: StoryFootnoteEntryPresentation.spacing) {
            Text(verbatim: presentation.marker.number)
                .font(.system(size: presentation.marker.pointSize, weight: .bold))
                .italic(false)
                .baselineOffset(presentation.marker.baselineOffset)
            noteBody
                .font(.system(StoryFootnoteEntryPresentation.textStyle.swiftUITextStyle))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.secondary)
        .padding(.top, StoryFootnoteEntryPresentation.topPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    @ViewBuilder private var noteBody: some View {
        switch entry {
        case let .nodes(nodes):
            StoryNodeSequenceView(
                nodes: nodes, inlineTextStyle: StoryFootnoteEntryPresentation.textStyle
            )
        default:
            ResolvedStoryEntryView(entry: entry, cardCatalog: cardCatalog)
        }
    }
}
