@testable import ArkhamHorrorShared
import Testing

/// A table at the start, middle or end of every spoken container keeps the pauses a bare
/// table gets against the text around that container.
@MainActor
@Suite("Story footnote spoken table boundaries")
struct StoryFootnoteSpokenBoundaryTests {
    @Test(
        "Table boundaries survive every container a footnote body joins",
        arguments: StoryFootnoteSpokenBoundaryMatrix.rows
    )
    func footnoteTableBoundariesSurviveContainers(row: StoryFootnoteSpokenBoundaryMatrix.Row) {
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("en") {
            #expect(
                StoryFootnoteEntryPresentation.spokenText(for: row.entry, cardCatalog: nil)
                    == row.expected,
                "\(row.label)"
            )
        }
    }

    @Test("Copilot's composite example pauses after the table")
    func footnoteCompositeTableThenText() {
        let body: ResolvedStoryEntry = .composite(entries: [
            .nodes([StoryFootnoteSpokenBoundaryMatrix.table]), .text("Then continue."),
        ])
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("en") {
            #expect(StoryFootnoteEntryPresentation(
                number: 4, entry: body, dynamicTypeSize: .large
            ).accessibilityLabel == "Footnote 4: Path, Cost. Then continue.")
        }
    }
}

enum StoryFootnoteSpokenBoundaryMatrix {
    struct Row: Sendable, CustomTestStringConvertible {
        let label: String
        let entry: ResolvedStoryEntry
        let expected: String

        var testDescription: String {
            label
        }
    }

    enum Position: String, CaseIterable {
        case start
        case middle
        case end

        /// The same reading for every container between "Before" and "after".
        var expected: String {
            switch self {
            case .start: "Before Path, Cost. one two after"
            case .middle: "Before one Path, Cost. two after"
            case .end: "Before one two Path, Cost. after"
            }
        }
    }

    static let table: StoryNode = .table(
        head: [StoryTableRow(cells: [
            StoryTableCell(isHeader: true, children: [.text("Path")]),
            StoryTableCell(isHeader: true, children: [.text("Cost")]),
        ])],
        body: []
    )

    /// Entry children for resolved containers: `one`, `two` and the table entry.
    static func entries(_ position: Position) -> [ResolvedStoryEntry] {
        let tableEntry: ResolvedStoryEntry = .nodes([table])
        return switch position {
        case .start: [tableEntry, .text("one"), .text("two")]
        case .middle: [.text("one"), tableEntry, .text("two")]
        case .end: [.text("one"), .text("two"), tableEntry]
        }
    }

    /// Node children for inline wrappers, whose prose joins without separators.
    static func inlineNodes(_ position: Position) -> [StoryNode] {
        switch position {
        case .start: [table, .text("one two")]
        case .middle: [.text("one"), table, .text("two")]
        case .end: [.text("one two"), table]
        }
    }

    /// List items for a node list: `one`, `two` and the table, one per item.
    static func listItems(_ position: Position) -> [[StoryNode]] {
        switch position {
        case .start: [[table], [.text("one")], [.text("two")]]
        case .middle: [[.text("one")], [table], [.text("two")]]
        case .end: [[.text("one")], [.text("two")], [table]]
        }
    }

    static func between(_ entry: ResolvedStoryEntry) -> ResolvedStoryEntry {
        .composite(entries: [.text("Before"), entry, .text("after")])
    }

    static let containers: [(String, @Sendable (Position) -> ResolvedStoryEntry)] = [
        ("composite", { .composite(entries: entries($0)) }),
        ("columns", { .columns(entries: entries($0)) }),
        ("resolved list", { position in
            .list(items: entries(position).map { ResolvedStoryListItem(entry: $0, nested: []) })
        }),
        ("group", { .nodes([.group(inlineNodes($0))]) }),
        ("paragraph", { .nodes([.paragraph(inlineNodes($0))]) }),
        ("node list item", { .nodes([.list(ordered: false, items: listItems($0))]) }),
    ]

    static var rows: [Row] {
        let matrix = containers.flatMap { name, make in
            Position.allCases.map { position in
                Row(
                    label: "\(name) \(position.rawValue)",
                    entry: between(make(position)),
                    expected: position.expected
                )
            }
        }
        return matrix + extraRows
    }

    static let extraRows: [Row] = [
        Row(
            label: "node list inside composite",
            entry: between(.nodes([.list(ordered: false, items: [[table]])])),
            expected: "Before Path, Cost. after"
        ),
        Row(
            label: "nested resolved list item",
            entry: .list(items: [
                ResolvedStoryListItem(
                    entry: .text("one"),
                    nested: [ResolvedStoryListItem(entry: .nodes([table]), nested: [])]
                ),
                ResolvedStoryListItem(entry: .text("two"), nested: []),
            ]),
            expected: "one Path, Cost. two"
        ),
        Row(
            label: "leading and trailing empty entries",
            entry: between(.composite(entries: [
                .divider, .text(""), .nodes([table]), .text("  "), .divider, .nodes([]),
            ])),
            expected: "Before Path, Cost. after"
        ),
        Row(
            label: "modified entry",
            entry: between(.modified(modifiers: [.validEntry], entry: .nodes([table]))),
            expected: "Before Valid Path, Cost. after"
        ),
        Row(
            label: "nested footnote",
            entry: .composite(entries: [
                .footnote(number: 3, entry: .nodes([table])), .text("after"),
            ]),
            expected: "Footnote 3: Path, Cost. after"
        ),
        Row(
            label: "no table",
            entry: .composite(entries: [
                .text("Before"),
                .list(items: [ResolvedStoryListItem(
                    entry: .text("one"),
                    nested: [ResolvedStoryListItem(entry: .text("two"), nested: [])]
                )]),
                .columns(entries: [.text("a"), .divider, .text(" b ")]),
                .nodes([.group([.text("x"), .footnoteMarker("2")]), .text(".")]),
                .modified(modifiers: [.invalidEntry], entry: .text("gone")),
            ]),
            expected: "Before one two a b x footnote 2. Invalid gone"
        ),
    ]
}
