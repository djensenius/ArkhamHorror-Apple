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

    static func resolver(
        entryKeys: [String], chunkEntries: String
    ) async throws -> LocaleCatalogResolver {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: entryKeys, chunkEntries: chunkEntries
        )
        return try await LocaleCatalogResolver(snapshot: documents.loadSnapshot())
    }
}
