@testable import ArkhamHorrorShared
import Testing

@Suite("Story HeaderEntry localization")
struct StoryHeaderEntryLocalizationTests {
    @Test("A HeaderEntry resolves through the vocabulary without flattening its structure")
    func headerEntryPreservesHeadingStructure() {
        let flavorText = FlavorText(
            title: nil, body: [.header(level: .level3, key: "story.heading")]
        )
        let resolved = StoryNarrativeLocalization.resolvedStory(
            for: flavorText, vocabulary: ["story.heading": "Synthetic heading"]
        )
        #expect(resolved?.body == [
            .heading(level: .level3, nodes: [.text("Synthetic heading")]),
        ])
    }

    @Test("A missing HeaderEntry key fails the whole story closed")
    func missingHeaderEntryKeyFailsClosed() {
        let flavorText = FlavorText(
            title: nil, body: [.header(level: .level1, key: "story.missing")]
        )
        #expect(StoryNarrativeLocalization.resolvedStory(for: flavorText) == nil)
    }

    @Test("A HeaderEntry resolves through one verified catalog snapshot as structured nodes")
    func productionHeaderEntryPreservesCatalogNodes() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["story.heading"],
            chunkEntries: """
            {"story.heading":{"form":"message","nodes":[{"type":"emphasis","style":"bold",\
            "children":[{"type":"text","value":"Synthetic heading"}]}],"variables":[]}}
            """
        )
        let snapshot = try await documents.loadSnapshot()
        let resolver = LocaleCatalogResolver(snapshot: snapshot)
        let flavorText = FlavorText(
            title: nil, body: [.header(level: .level1, key: "story.heading")]
        )
        #expect(StoryNarrativeLocalization.resolve(
            flavorText,
            resolver: resolver,
            catalogUnavailability: nil
        ) == .resolved(ResolvedStory(
            title: nil,
            body: [
                .heading(
                    level: .level1,
                    nodes: [.emphasis(.bold, [.text("Synthetic heading")])]
                ),
            ]
        )))
    }

    @Test("HeaderEntry resolution fails closed for a missing catalog or missing catalog key")
    func productionHeaderEntryMissingAuthorityFailsClosed() async throws {
        let chromeNamedFlavorText = FlavorText(
            title: nil, body: [.header(level: .level1, key: "setup")]
        )
        #expect(StoryNarrativeLocalization.resolve(
            chromeNamedFlavorText,
            resolver: nil,
            catalogUnavailability: .catalog(.notAdvertised)
        ) == .unavailable(.catalog(.notAdvertised)))

        let documents = try SyntheticLocaleCatalogDocuments.make()
        let snapshot = try await documents.loadSnapshot()
        let resolver = LocaleCatalogResolver(snapshot: snapshot)
        let missingFlavorText = FlavorText(
            title: nil, body: [.header(level: .level1, key: "story.missing")]
        )
        #expect(StoryNarrativeLocalization.resolve(
            missingFlavorText,
            resolver: resolver,
            catalogUnavailability: nil
        ) == .unavailable(.missingKey))
    }

    @Test("A HeaderEntry uses the verified catalog instead of chrome fallback text")
    func productionHeaderEntryUsesCatalogValue() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            pack: "core",
            entryKeys: ["setup"],
            chunkEntries: """
            {"setup":{"form":"message","nodes":[\
            {"type":"text","value":"Catalog setup heading"}],"variables":[]}}
            """
        )
        let snapshot = try await documents.loadSnapshot()
        let resolver = LocaleCatalogResolver(snapshot: snapshot)
        let flavorText = FlavorText(
            title: nil, body: [.header(level: .level1, key: "setup")]
        )
        #expect(StoryNarrativeLocalization.resolve(
            flavorText,
            resolver: resolver,
            catalogUnavailability: nil
        ) == .resolved(ResolvedStory(
            title: nil,
            body: [.heading(level: .level1, nodes: [.text("Catalog setup heading")])]
        )))
    }

    @Test("An unsupported HeaderEntry catalog node fails the whole story closed")
    func productionHeaderEntryUnsupportedNodeFailsClosed() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["story.heading"],
            chunkEntries: """
            {"story.heading":{"form":"message","nodes":[{"type":"image","role":"card",\
            "assetPath":"cards/example.png","styles":[]}],"variables":[]}}
            """
        )
        let snapshot = try await documents.loadSnapshot()
        let resolver = LocaleCatalogResolver(snapshot: snapshot)
        let flavorText = FlavorText(
            title: nil, body: [.header(level: .level3, key: "story.heading")]
        )
        #expect(StoryNarrativeLocalization.resolve(
            flavorText,
            resolver: resolver,
            catalogUnavailability: nil
        ) == .unavailable(.unsupportedEntry))
    }
}
