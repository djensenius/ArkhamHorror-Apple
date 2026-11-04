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
            spokenText(for: nodes)
        case let .modified(modifiers, entry):
            // `ModifiedResolvedStoryEntryView` labels a valid/invalid entry with an icon.
            joined([
                StoryFlavorEntryStatus.status(for: modifiers)?.accessibilityLabel ?? "",
                spokenText(for: entry, cardCatalog: cardCatalog),
            ])
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

    /// The block-aware VoiceOver text of a note body's nodes. Prose reads exactly as
    /// ``StoryNodePresentation/accessibilityLabel(for:)``; a table (silent in
    /// ``StoryNode/spokenText``) reads its header rows, then each body row, with ", " between
    /// cells and ". " between rows. It is set off from preceding text by a space and ends with
    /// ". " before following text, never doubling punctuation or spaces.
    static func spokenText(for nodes: [StoryNode]) -> String {
        var result = ""
        var followsTable = false
        for node in nodes {
            let isTable = if case .table = node {
                true
            } else {
                false
            }
            let part = spokenText(for: node)
            guard !part.isEmpty else { continue }
            if followsTable {
                if let last = result.last, !spokenPunctuation.contains(last) {
                    result += "."
                }
                if part.first?.isWhitespace == false {
                    result += " "
                }
            } else if isTable, let last = result.last, !last.isWhitespace {
                result += " "
            }
            result += part
            followsTable = isTable
        }
        return result
    }

    /// Punctuation after which a table separator or pause adds only a space.
    private static let spokenPunctuation: Set<Character> = [".", ",", "!", "?", ":", ";", "…"]

    /// Joins trimmed, non-empty parts with `separator` and a space, or only a space when the
    /// preceding part already ends in punctuation.
    private static func spokenJoined(_ parts: [String], separator: String) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: "") { result, part in
                if let last = result.last {
                    result += spokenPunctuation.contains(last) ? " " : separator + " "
                }
                result += part
            }
    }

    private static func spokenText(for node: StoryNode) -> String {
        switch node {
        case let .table(head, body):
            spokenJoined(
                (head + body).map { row in
                    spokenJoined(row.cells.map { spokenText(for: $0.children) }, separator: ",")
                },
                separator: "."
            )
        case let .paragraph(children), let .group(children), let .heading(_, children),
             let .emphasis(_, children), let .cardReference(_, children):
            spokenText(for: children)
        case let .list(_, items):
            items.map { spokenText(for: $0) }.joined(separator: " ")
        case .text, .lineBreak, .icon, .semanticIcon, .footnoteMarker, .image, .rule:
            node.spokenText
        }
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
            Self.noteBody(entry: entry, cardCatalog: cardCatalog)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.secondary)
        .padding(.top, StoryFootnoteEntryPresentation.topPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    /// The note body in caption metrics: the caption font for its text, and the caption
    /// `storyEntryInlineTextStyle` that every nested ``ResolvedStoryEntryView`` hands to its
    /// icons, `[^N]` markers, headings and PlainText. The wiring test renders this too.
    static func noteBody(
        entry: ResolvedStoryEntry, cardCatalog: CardCatalogSnapshot?
    ) -> some View {
        ResolvedStoryEntryView(entry: entry, cardCatalog: cardCatalog)
            .font(.system(StoryFootnoteEntryPresentation.textStyle.swiftUITextStyle))
            .environment(\.storyEntryInlineTextStyle, StoryFootnoteEntryPresentation.textStyle)
    }
}
