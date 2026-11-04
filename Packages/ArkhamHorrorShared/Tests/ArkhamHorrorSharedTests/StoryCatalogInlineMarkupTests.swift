@testable import ArkhamHorrorShared
import Foundation
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

    @Test("Catalog story text splits [^N] inside list items, table cells and card references")
    func catalogStoryTextSplitsNestedFootnoteMarkers() async throws {
        let resolver = try await Self.resolver(
            entryKeys: ["story.nestedFootnotes"],
            chunkEntries: """
            {"story.nestedFootnotes":{"form":"message","nodes":[\
            {"type":"list","ordered":false,"styles":[],"items":[\
            {"styles":[],"children":[{"type":"text","value":"Item[^1]"}]}]},\
            {"type":"table","styles":[],"head":[{"styles":[],"cells":[\
            {"header":true,"styles":[],"children":[{"type":"text","value":"Head[^2]"}]}]}],\
            "body":[{"styles":[],"cells":[\
            {"header":false,"styles":[],"children":[{"type":"text","value":"Cell[^3]"}]}]}]},\
            {"type":"cardRef","code":"01001","styles":[],"children":[\
            {"type":"text","value":"Roland[^4]"}]}],"variables":[]}}
            """
        )
        let flavorText = FlavorText(title: nil, body: [.basic(text: "$story.nestedFootnotes")])
        let nodes: [StoryNode] = [
            .list(ordered: false, items: [[.text("Item"), .footnoteMarker("1")]]),
            .table(
                head: [StoryTableRow(cells: [
                    StoryTableCell(isHeader: true, children: [.text("Head"), .footnoteMarker("2")]),
                ])],
                body: [StoryTableRow(cells: [
                    StoryTableCell(
                        isHeader: false, children: [.text("Cell"), .footnoteMarker("3")]
                    ),
                ])]
            ),
            .cardReference(code: "01001", children: [.text("Roland"), .footnoteMarker("4")]),
        ]
        #expect(StoryNarrativeLocalization.resolve(
            flavorText, resolver: resolver, catalogUnavailability: nil
        ) == .resolved(ResolvedStory(title: nil, body: [.nodes(nodes)])))
    }

    @Test("A FootnoteEntry body keeps catalog italics and its own [^N] markers")
    func footnoteEntryBodyKeepsCatalogItalicsAndMarkers() async throws {
        let resolver = try await Self.resolver(
            entryKeys: ["theDunwichLegacy.prologue.footnote2"],
            chunkEntries: """
            {"theDunwichLegacy.prologue.footnote2":{"form":"message","nodes":[\
            {"type":"text","value":"Translated as "},\
            {"type":"emphasis","style":"italic","children":[\
            {"type":"text","value":"DH[^4]"}]},\
            {"type":"text","value":"."}],"variables":[]}}
            """
        )
        let json = #"""
        {"tag":"Read","flavorText":{"title":null,"body":[{"tag":"FootnoteEntry","number":2,
        "entry":{"tag":"I18nEntry","key":"theDunwichLegacy.prologue.footnote2","variables":{}}}]},
        "readChoices":{"tag":"BasicReadChoices","contents":[{"tag":"Label","label":"$continue",
        "messages":[]}]},"readCards":null}
        """#
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: Data(json.utf8)
        )
        let flavorText = try #require(payload.supportedQuestion?.story?.flavorText)
        let note: [StoryNode] = [
            .text("Translated as "),
            .emphasis(.italic, [.text("DH"), .footnoteMarker("4")]),
            .text("."),
        ]
        #expect(StoryNarrativeLocalization.resolve(
            flavorText, resolver: resolver, catalogUnavailability: nil
        ) == .resolved(ResolvedStory(
            title: nil, body: [.footnote(number: 2, entry: .nodes(note))]
        )))
    }

    @Test("A footnote number interpolated from a variable still splits into a marker")
    func interpolatedFootnoteNumberSplitsAcrossTextSiblings() async throws {
        let resolver = try await Self.interpolationResolver()
        let variables: JSONValue = .object(["number": .string("5")])
        // The resolver keeps the interpolated value as its own text sibling.
        #expect(resolver.render(key: "story.noteNumber", variables: variables)
            == .success([.text("Note[^"), .text("5"), .text("].")]))

        let nodes = try Self.narrativeNodes("story.noteNumber", variables, resolver)
        #expect(nodes == [.text("Note"), .footnoteMarker("5"), .text(".")])
        #expect(nodes.map(\.plainText).joined() == "Note5.")
        #expect(StoryNodePresentation.accessibilityLabel(for: nodes) == "Note footnote 5.")
    }

    @Test("Non-digit interpolations and text split by emphasis keep their literal siblings")
    func nonFootnoteInterpolationsStayLiteralAndUnmerged() async throws {
        let resolver = try await Self.interpolationResolver()
        let name: JSONValue = .object(["name": .string("x")])
        #expect(try Self.narrativeNodes("story.noteName", name, resolver)
            == [.text("Note[^"), .text("x"), .text("].")])

        #expect(try Self.narrativeNodes("story.noteEmphasis", .object([:]), resolver)
            == [.text("Note[^"), .emphasis(.bold, [.text("5")]), .text("].")])
    }

    @Test("VoiceOver announces a footnote marker as a separate footnote number")
    func spokenLabelSeparatesFootnoteMarkers() {
        let paragraph: [StoryNode] = [.paragraph([
            .text("Olaus wrote"), .footnoteMarker("1"), .text(" in 1927"),
            .emphasis(.italic, [.footnoteMarker("5")]),
        ])]
        #expect(
            StoryNodePresentation.accessibilityLabel(for: paragraph)
                == "Olaus wrote footnote 1 in 1927 footnote 5"
        )
        // Flattening (titles) keeps the bare number, like the web's `<sup>` text content.
        #expect(paragraph.map(\.plainText).joined() == "Olaus wrote1 in 19275")
    }

    static func interpolationResolver() async throws -> LocaleCatalogResolver {
        try await resolver(
            entryKeys: ["story.noteNumber", "story.noteName", "story.noteEmphasis"],
            chunkEntries: """
            {"story.noteNumber":{"form":"message","nodes":[\
            {"type":"text","value":"Note[^"},\
            {"type":"var","name":"number","source":"named","role":"text"},\
            {"type":"text","value":"]."}],\
            "variables":[{"name":"number","source":"named","role":"text"}]},\
            "story.noteName":{"form":"message","nodes":[\
            {"type":"text","value":"Note[^"},\
            {"type":"var","name":"name","source":"named","role":"text"},\
            {"type":"text","value":"]."}],\
            "variables":[{"name":"name","source":"named","role":"text"}]},\
            "story.noteEmphasis":{"form":"message","nodes":[\
            {"type":"text","value":"Note[^"},\
            {"type":"emphasis","style":"bold","children":[{"type":"text","value":"5"}]},\
            {"type":"text","value":"]."}],"variables":[]}}
            """
        )
    }

    /// The narrative (story text) nodes for catalog `key`, after footnote splitting.
    static func narrativeNodes(
        _ key: String, _ variables: JSONValue, _ resolver: LocaleCatalogResolver
    ) throws -> [StoryNode] {
        let resolution = try StoryNarrativeLocalization.resolveProductionCatalogEntry(
            key,
            variables: variables,
            resolver: resolver,
            catalogUnavailability: .catalog(.transportFailure),
            makeFallback: { .text($0) },
            makeResolved: { .nodes($0.nodes) }
        ).get()
        guard case let .nodes(nodes) = resolution.entry else { return [] }
        return nodes
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

/// TASK-1.22.7: every story path the web runs through `formatContent` splits `[^N]`.
extension StoryCatalogInlineMarkupTests {
    @Test("Literal basic story text splits [^N] like catalog text; plain text stays .text")
    func literalBasicTextSplitsFootnoteMarkers() {
        let flavorText = FlavorText(title: nil, body: [
            .basic(text: "Olaus wrote[^1] in 1927[^5]."),
            .basic(text: "No note [^x] here."),
        ])
        let nodes: [StoryNode] = [
            .text("Olaus wrote"), .footnoteMarker("1"), .text(" in 1927"),
            .footnoteMarker("5"), .text("."),
        ]
        let body: [ResolvedStoryEntry] = [.nodes(nodes), .text("No note [^x] here.")]
        #expect(StoryNarrativeLocalization.resolve(
            flavorText, resolver: nil, catalogUnavailability: nil
        ) == .resolved(ResolvedStory(title: nil, body: body)))
        #expect(
            StoryNodePresentation.accessibilityLabel(for: nodes)
                == "Olaus wrote footnote 1 in 1927 footnote 5."
        )
    }

    @Test("Literal and catalog story titles split [^N] into title nodes and speak them")
    func storyTitlesSplitFootnoteMarkers() async throws {
        let resolver = try await Self.resolver(
            entryKeys: ["story.footnoteHeading"],
            chunkEntries: """
            {"story.footnoteHeading":{"form":"message","nodes":[\
            {"type":"text","value":"Heading[^2]"}],"variables":[]}}
            """
        )
        let literal = StoryNarrativeLocalization.resolve(
            FlavorText(title: "Wormius 1927[^5]", body: []),
            resolver: resolver, catalogUnavailability: nil
        ).story
        let literalNodes: [StoryNode] = [.text("Wormius 1927"), .footnoteMarker("5")]
        #expect(literal == ResolvedStory(
            title: "Wormius 19275", titleNodes: literalNodes, body: []
        ))
        #expect(
            StoryNodePresentation.accessibilityLabel(for: literal?.titleNodes ?? [])
                == "Wormius 1927 footnote 5"
        )

        let catalog = StoryNarrativeLocalization.resolve(
            FlavorText(title: "$story.footnoteHeading", body: []),
            resolver: resolver, catalogUnavailability: nil
        ).story
        let catalogNodes: [StoryNode] = [.text("Heading"), .footnoteMarker("2")]
        #expect(catalog == ResolvedStory(title: "Heading2", titleNodes: catalogNodes, body: []))
        #expect(
            StoryNodePresentation.accessibilityLabel(for: catalog?.titleNodes ?? [])
                == "Heading footnote 2"
        )

        // A title without a reference keeps its plain string and no nodes.
        #expect(StoryNarrativeLocalization.resolve(
            FlavorText(title: "Plain [^x] title", body: []),
            resolver: resolver, catalogUnavailability: nil
        ).story == ResolvedStory(title: "Plain [^x] title", titleNodes: nil, body: []))
    }

    @Test("The catalog game log keeps [^N] literal while story text splits it")
    func catalogGameLogKeepsFootnoteMarkersLiteral() async throws {
        let resolver = try await Self.resolver(
            entryKeys: ["story.footnoteHeading"],
            chunkEntries: """
            {"story.footnoteHeading":{"form":"message","nodes":[\
            {"type":"text","value":"Heading[^2]"}],"variables":[]}}
            """
        )
        let renderer = GameLogPartRenderer(resolver: resolver)
        #expect(
            renderer.render(.i18n(key: "story.footnoteHeading", variables: [:]))
                == [.text("Heading[^2]")]
        )
        #expect(try Self.narrativeNodes("story.footnoteHeading", .object([:]), resolver)
            == [.text("Heading"), .footnoteMarker("2")])
    }
}
