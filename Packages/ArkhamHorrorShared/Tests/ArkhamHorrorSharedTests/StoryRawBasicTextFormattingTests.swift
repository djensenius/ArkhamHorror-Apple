@testable import ArkhamHorrorShared
import Foundation
import Testing

/// TASK-1.22.11: literal (non-`$`) basic story text goes through the web's `formatContent`
/// (fork `FormattedEntry.vue`, `helpers.ts:229-238`) like catalog story text, so `{icon}`
/// tokens and `_bold_`/`*italic*` render instead of showing literally. Text without markup
/// keeps its exact `.text` entry.
@Suite("Raw basic story text formatting")
struct StoryRawBasicTextFormattingTests {
    private static func body(_ entries: [FlavorTextEntry]) -> StoryResolution {
        StoryNarrativeLocalization.resolve(
            FlavorText(title: nil, body: entries), resolver: nil, catalogUnavailability: nil
        )
    }

    private static func resolved(_ body: [ResolvedStoryEntry]) -> StoryResolution {
        .resolved(ResolvedStory(title: nil, body: body))
    }

    private static let iconNodes: [StoryNode] = [
        .text("Draw a "), .semanticIcon(.chaosToken(.skull)), .text(" token, an "),
        .semanticIcon(.chaosToken(.elderSign)), .text(" and a "), .icon("runeM"),
        .text(" rune, then "), .icon("action"), .text(" "), .icon("runeQ"), .text("."),
    ]

    @Test("Literal basic text renders {icon} and rune tokens as catalog icon nodes")
    func literalIconsRenderAsNodes() {
        let text = "Draw a {skull} token, an {elderSign} and a {runeM} rune, then "
            + "{action} [tdc_rune_q]."
        #expect(Self.body([.basic(text: text)]) == Self.resolved([.nodes(Self.iconNodes)]))
    }

    @Test("VoiceOver reads raw basic text icons by their spoken names")
    func literalIconsSpeakTheirNames() {
        #expect(
            StoryNodePresentation.accessibilityLabel(for: Self.iconNodes)
                == "Draw a skull token, an elder sign and a rune m rune, then action rune q."
        )
        let emphasis: [StoryNode] = [
            .emphasis(.italic, [.text("Test "), .semanticIcon(.skill(.willpower))]),
            .footnoteMarker("2"),
        ]
        #expect(Self.body([.basic(text: "*Test {willpower}*[^2]")]) == Self.resolved([
            .nodes(emphasis),
        ]))
        #expect(
            StoryNodePresentation.accessibilityLabel(for: emphasis)
                == "Test willpower footnote 2"
        )
    }

    @Test("A literal icon renders exactly like the same catalog icon variable")
    func literalIconMatchesCatalogStoryText() async throws {
        let resolver = try await StoryCatalogInlineMarkupTests.resolver(
            entryKeys: ["story.rune"],
            chunkEntries: """
            {"story.rune":{"form":"message","nodes":[\
            {"type":"text","value":"Open the "},\
            {"type":"var","name":"runeM","source":"named","role":"icon"},\
            {"type":"text","value":" gate"}],\
            "variables":[{"name":"runeM","source":"named","role":"icon"}]}}
            """
        )
        let catalog = StoryNarrativeLocalization.resolve(
            FlavorText(title: nil, body: [.basic(text: "$story.rune")]),
            resolver: resolver, catalogUnavailability: nil
        )
        let literal = StoryNarrativeLocalization.resolve(
            FlavorText(title: nil, body: [.basic(text: "Open the {runeM} gate")]),
            resolver: resolver, catalogUnavailability: nil
        )
        #expect(literal == catalog)
        #expect(literal == Self.resolved([
            .nodes([.text("Open the "), .icon("runeM"), .text(" gate")]),
        ]))
    }

    @Test("Literal basic text renders _bold_ and *italic* emphasis")
    func literalEmphasisRenders() {
        #expect(Self.body([.basic(text: "_Bold_ then *italic* end")]) == Self.resolved([
            .nodes([
                .emphasis(.bold, [.text("Bold")]), .text(" then "),
                .emphasis(.italic, [.text("italic")]), .text(" end"),
            ]),
        ]))
    }

    @Test("Literal basic text mixing an icon and a [^N] marker splits both")
    func literalIconAndFootnoteMarker() {
        #expect(Self.body([.basic(text: "Test {intellect}[^3] now.")]) == Self.resolved([
            .nodes([
                .text("Test "), .semanticIcon(.skill(.intellect)), .footnoteMarker("3"),
                .text(" now."),
            ]),
        ]))
    }

    @Test("Escape-only literal text unescapes to plain .text, like the web")
    func escapeOnlyTextUnescapes() {
        #expect(Self.body([
            .basic(text: "a{asterisk}b"), .basic(text: "x{underscore}y{asterisk}"),
        ]) == Self.resolved([.text("a*b"), .text("x_y*")]))
    }

    @Test("Text without markup keeps its exact .text entry")
    func markupFreeTextIsUnchanged() {
        let texts = [
            "Not an i18n key", "", "No note [^x] here.", "a_b", "Reach {neutral} ground",
            "Contract fixture flavor text.", "List item",
        ]
        #expect(Self.body(texts.map { .basic(text: $0) }) == Self.resolved(texts.map {
            .text($0)
        }))
        #expect(Self.body([
            .basic(text: "$continue"), .basic(text: "$setup"),
            .i18n(key: "continue", variables: .object([:])),
            .modify(modifiers: [.blueEntry], entry: .basic(text: "Modified")),
        ]) == Self.resolved([
            .text("Continue"), .text("Setup"), .text("Continue"),
            .modified(modifiers: [.blueEntry], entry: .text("Modified")),
        ]))
    }

    @Test("Literal [^N] text keeps its TASK-1.22.7 marker split and spoken form")
    func literalFootnoteSplitIsUnchanged() {
        let nodes: [StoryNode] = [
            .text("Olaus wrote"), .footnoteMarker("1"), .text(" in 1927"),
            .footnoteMarker("5"), .text("."),
        ]
        #expect(Self.body([.basic(text: "Olaus wrote[^1] in 1927[^5].")]) == Self.resolved([
            .nodes(nodes),
        ]))
        #expect(
            StoryNodePresentation.accessibilityLabel(for: nodes)
                == "Olaus wrote footnote 1 in 1927 footnote 5."
        )
    }
}
