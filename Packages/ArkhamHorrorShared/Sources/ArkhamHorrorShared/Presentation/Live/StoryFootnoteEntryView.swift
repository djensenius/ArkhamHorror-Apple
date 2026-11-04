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

    /// The VoiceOver text of a resolved note body, matching what `ResolvedStoryEntryView`
    /// shows for each entry.
    static func spokenText(
        for entry: ResolvedStoryEntry, cardCatalog: CardCatalogSnapshot?
    ) -> String {
        spokenRun(for: entry, cardCatalog: cardCatalog).text
    }

    // The trimmed spoken run of a resolved entry. Sibling entries join with a space, except
    // that a table at an entry's edge keeps the same pauses as a table in a node sequence.
    // swiftlint:disable:next cyclomatic_complexity
    private static func spokenRun(
        for entry: ResolvedStoryEntry, cardCatalog: CardCatalogSnapshot?
    ) -> SpokenRun {
        func joined(_ runs: [SpokenRun]) -> SpokenRun {
            joinedRuns(runs.filter { !$0.text.isEmpty }, separator: " ")
        }
        func spokenEntries(_ entries: [ResolvedStoryEntry]) -> SpokenRun {
            joined(entries.map { spokenRun(for: $0, cardCatalog: cardCatalog) })
        }
        func spokenItems(_ items: [ResolvedStoryListItem]) -> SpokenRun {
            joined(items.map { item in
                joined([
                    spokenRun(for: item.entry, cardCatalog: cardCatalog),
                    spokenItems(item.nested),
                ])
            })
        }
        let run: SpokenRun = switch entry {
        case let .text(value):
            SpokenRun(text: value)
        case let .nodes(nodes), let .heading(_, nodes):
            spokenRun(for: nodes)
        case let .modified(modifiers, entry):
            // `ModifiedResolvedStoryEntryView` labels a valid/invalid entry with an icon.
            joined([
                SpokenRun(
                    text: StoryFlavorEntryStatus.status(for: modifiers)?.accessibilityLabel ?? ""
                ),
                spokenRun(for: entry, cardCatalog: cardCatalog),
            ])
        case let .composite(entries), let .columns(entries):
            spokenEntries(entries)
        case let .list(items):
            spokenItems(items)
        case let .cardReference(cardCode, _):
            SpokenRun(text: cardCatalog?.displayName(for: cardCode) ?? "Card \(cardCode.rawValue)")
        case let .tarotReference(arcana):
            SpokenRun(text: "Tarot \(arcana)")
        case let .chaosTokenReference(face):
            SpokenRun(text: "Chaos token \(face.rawValue)")
        case let .chaosTokenMorph(from, target):
            SpokenRun(text: "Chaos token \(from.rawValue) to \(target.rawValue)")
        case .divider:
            SpokenRun()
        case let .footnote(number, entry):
            footnoteRun(number: number, body: spokenRun(for: entry, cardCatalog: cardCatalog))
        }
        return run.trimmed
    }

    /// A nested note's label keeps its body's closing table only where the localized label
    /// ends with the body.
    private static func footnoteRun(number: Int, body: SpokenRun) -> SpokenRun {
        let label = accessibilityLabel(number: number, body: body.text)
        return SpokenRun(
            text: label,
            endsWithTable: body.endsWithTable && !body.text.isEmpty && label.hasSuffix(body.text)
        )
    }

    /// The block-aware VoiceOver text of a note body's nodes. Prose reads exactly as
    /// ``StoryNodePresentation/accessibilityLabel(for:)``; a table (silent in
    /// ``StoryNode/spokenText``) reads its header rows, then each body row, with ", " between
    /// cells and ". " between rows. It is set off from preceding text by a space and ends with
    /// ". " before following text, never doubling punctuation or spaces, also when it starts
    /// or ends a list item.
    static func spokenText(for nodes: [StoryNode]) -> String {
        spokenRun(for: nodes).text
    }

    /// Spoken text plus whether its first or last non-empty part is a table, so a table at
    /// the edge of a list item keeps its pauses in the enclosing sequence.
    private struct SpokenRun {
        var text = ""
        var startsWithTable = false
        var endsWithTable = false

        /// Without surrounding whitespace; the table edges are unaffected.
        var trimmed: SpokenRun {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpokenRun(
                text: text,
                startsWithTable: startsWithTable && !text.isEmpty,
                endsWithTable: endsWithTable && !text.isEmpty
            )
        }
    }

    private static func spokenRun(for nodes: [StoryNode]) -> SpokenRun {
        joinedRuns(spokenLeaves(nodes).map(spokenRun(for:)), separator: "")
    }

    /// The one table-boundary rule for node sequences (`separator` "") and for node list
    /// items and non-empty resolved entries (`separator` " "): after a table, a non-empty
    /// part follows ". " (or a space after punctuation, nothing extra before leading
    /// whitespace) and empty parts are skipped; before a table, a space unless whitespace is
    /// already there. Without tables, parts are joined with `separator` exactly as before.
    private static func joinedRuns(_ runs: [SpokenRun], separator: String) -> SpokenRun {
        var result = SpokenRun()
        for (index, run) in runs.enumerated() {
            if result.endsWithTable {
                guard !run.text.isEmpty else { continue }
                if let last = result.text.last, !spokenPunctuation.contains(last) {
                    result.text += "."
                }
                if run.text.first?.isWhitespace == false {
                    result.text += " "
                }
            } else if run.startsWithTable {
                if let last = result.text.last, !last.isWhitespace {
                    result.text += " "
                }
            } else if index > 0 {
                result.text += separator
            }
            guard !run.text.isEmpty else { continue }
            if result.text.allSatisfy(\.isWhitespace) {
                result.startsWithTable = run.startsWithTable
            }
            result.text += run.text
            result.endsWithTable = run.endsWithTable
        }
        return result
    }

    /// The nodes with every wrapper that ``StoryNode/spokenText`` joins transparently
    /// (paragraph, group, heading, emphasis, card reference) replaced by its children, so a
    /// wrapped table gets the same pauses as a bare one.
    private static func spokenLeaves(_ nodes: [StoryNode]) -> [StoryNode] {
        nodes.flatMap { node -> [StoryNode] in
            switch node {
            case let .paragraph(children), let .group(children), let .heading(_, children),
                 let .emphasis(_, children), let .cardReference(_, children):
                spokenLeaves(children)
            case .text, .lineBreak, .icon, .semanticIcon, .footnoteMarker, .image, .rule, .list,
                 .table:
                [node]
            }
        }
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

    private static func spokenRun(for node: StoryNode) -> SpokenRun {
        switch node {
        case let .table(head, body):
            let text = spokenJoined(
                (head + body).map { row in
                    spokenJoined(row.cells.map { spokenText(for: $0.children) }, separator: ",")
                },
                separator: "."
            )
            return SpokenRun(
                text: text, startsWithTable: !text.isEmpty, endsWithTable: !text.isEmpty
            )
        case let .paragraph(children), let .group(children), let .heading(_, children),
             let .emphasis(_, children), let .cardReference(_, children):
            return spokenRun(for: children)
        case let .list(_, items):
            return joinedRuns(items.map { spokenRun(for: $0) }, separator: " ")
        case .text, .lineBreak, .icon, .semanticIcon, .footnoteMarker, .image, .rule:
            return SpokenRun(text: node.spokenText)
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
