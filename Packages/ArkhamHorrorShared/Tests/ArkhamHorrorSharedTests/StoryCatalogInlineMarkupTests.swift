@testable import ArkhamHorrorShared
import Testing

@Suite("Story catalog inline icons and footnotes")
struct StoryCatalogInlineMarkupTests {
    @Test("A story-text runeM icon variable renders the shared rune glyph")
    func storyTextRuneIconVariableRendersRuneGlyph() async throws {
        let resolver = try await Self.resolver(
            entryKeys: ["story.rune"],
            chunkEntries: """
            {"story.rune":{"form":"message","nodes":[\
            {"type":"text","value":"Open the "},\
            {"type":"var","name":"runeM","source":"named","role":"icon"},\
            {"type":"text","value":" gate"}],\
            "variables":[{"name":"runeM","source":"named","role":"icon"}]}}
            """
        )
        let flavorText = FlavorText(title: nil, body: [.basic(text: "$story.rune")])
        let nodes: [StoryNode] = [.text("Open the "), .icon("runeM"), .text(" gate")]
        #expect(StoryNarrativeLocalization.resolve(
            flavorText, resolver: resolver, catalogUnavailability: nil
        ) == .resolved(ResolvedStory(title: nil, body: [.nodes(nodes)])))
        let slim = WebIconFontAvailability(registrations: [
            .arkhamSlim: .init(
                family: .arkhamSlim, postScriptName: "arkhamslim", supportedScalars: [0xE90C]
            ),
        ])
        #expect(StoryInlineTextRenderer.namedIconGlyph("runeM", iconFonts: slim) == .webGlyph(
            iconName: "rune-M", fontName: "arkhamslim", glyph: "\u{E90C}"
        ))
        #expect(StoryNodePresentation.accessibilityLabel(for: nodes) == "Open the rune m gate")
    }

    @Test("Catalog story text splits [^N] footnote markers; the catalog log keeps them literal")
    func catalogStoryTextSplitsFootnoteMarkers() async throws {
        let resolver = try await Self.resolver(
            entryKeys: ["story.footnote", "story.footnoteHeading"],
            chunkEntries: """
            {"story.footnote":{"form":"message","nodes":[\
            {"type":"text","value":"Olaus wrote[^1] of "},\
            {"type":"emphasis","style":"italic","children":[\
            {"type":"text","value":"the book[^23]"}]},\
            {"type":"text","value":" and [^x] [^]."}],"variables":[]},\
            "story.footnoteHeading":{"form":"message","nodes":[\
            {"type":"text","value":"Heading[^2]"}],"variables":[]}}
            """
        )
        let flavorText = FlavorText(title: nil, body: [
            .basic(text: "$story.footnote"),
            .header(level: .level3, key: "story.footnoteHeading"),
        ])
        let body: [ResolvedStoryEntry] = [
            .nodes([
                .text("Olaus wrote"), .footnoteMarker("1"), .text(" of "),
                .emphasis(.italic, [.text("the book"), .footnoteMarker("23")]),
                .text(" and [^x] [^]."),
            ]),
            .heading(level: .level3, nodes: [.text("Heading"), .footnoteMarker("2")]),
        ]
        #expect(StoryNarrativeLocalization.resolve(
            flavorText, resolver: resolver, catalogUnavailability: nil
        ) == .resolved(ResolvedStory(title: nil, body: body)))
        // The resolver itself (shared with the game log) leaves the marker as text.
        #expect(
            resolver.render(key: "story.footnoteHeading", variables: .object([:]))
                == .success([.text("Heading[^2]")])
        )
    }

    static func resolver(
        entryKeys: [String], chunkEntries: String
    ) async throws -> LocaleCatalogResolver {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: entryKeys, chunkEntries: chunkEntries
        )
        return try await LocaleCatalogResolver(snapshot: documents.loadSnapshot())
    }
}
