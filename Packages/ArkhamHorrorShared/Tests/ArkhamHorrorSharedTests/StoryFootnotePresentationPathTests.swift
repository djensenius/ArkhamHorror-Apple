@testable import ArkhamHorrorShared
import Foundation
import Testing

/// A multi-choice Read (the Dunwich prologue) is update-required as a governed Read question,
/// so its story reaches the prompt through the semantic presentation flavor path.
@MainActor
extension AppModelLiveGameTests {
    private var footnoteFlavorBody: [JSONValue] {
        [
            .object([
                "tag": .string("I18nEntry"),
                "key": .string("story.prose"),
                "variables": .object([:]),
            ]),
            .object([
                "tag": .string("FootnoteEntry"),
                "number": .number(Self.footnoteNumber("2")),
                "entry": .object([
                    "tag": .string("I18nEntry"),
                    "key": .string("theDunwichLegacy.prologue.footnote2"),
                    "variables": .object([:]),
                ]),
            ]),
            // Malformed: no entry. Fails closed to an unknown entry, in place.
            .object([
                "tag": .string("FootnoteEntry"),
                "number": .number(Self.footnoteNumber("3")),
            ]),
        ]
    }

    private static func footnoteNumber(_ text: String) -> JSONNumber {
        // swiftlint:disable:next force_try
        try! JSONNumber(exactDecimalLiteral: text)
    }

    @Test("Semantic presentation flavor path renders footnote bodies in place with a catalog")
    func semanticPresentationFlavorPathRendersFootnotesWithCatalog() async throws {
        let documents = try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["story.prose", "theDunwichLegacy.prologue.footnote2"],
            chunkEntries: """
            {"story.prose":{"form":"message","nodes":[\
            {"type":"text","value":"Armitage wrote[^2]."}],"variables":[]},\
            "theDunwichLegacy.prologue.footnote2":{"form":"message","nodes":[\
            {"type":"text","value":"Olaus Wormius, "},\
            {"type":"emphasis","style":"italic","children":[\
            {"type":"text","value":"Necronomicon"}]},\
            {"type":"text","value":" (1228)[^3]."}],"variables":[]}}
            """
        )
        let (model, _) = makeCatalogSignedInModel(documents: documents)
        await model.flowTask?.value
        await model.localeCatalogTask?.value
        let flavorText = QuestionPresentation.FlavorText(title: nil, body: footnoteFlavorBody)
        let resolution = try #require(model.storyResolution(for: flavorText)?.story)
        #expect(resolution.body == [
            .nodes([.text("Armitage wrote"), .footnoteMarker("2"), .text(".")]),
            .footnote(number: 2, entry: .nodes([
                .text("Olaus Wormius, "),
                .emphasis(.italic, [.text("Necronomicon")]),
                .text(" (1228)"), .footnoteMarker("3"), .text("."),
            ])),
            .text("Unsupported story entry: FootnoteEntry"),
        ])
    }

    @Test("Semantic presentation flavor path keeps footnote bodies readable without a catalog")
    func semanticPresentationFlavorPathRendersFootnotesWithoutCatalog() async throws {
        let (model, _) = makeSignedInModel()
        await model.flowTask?.value
        let flavorText = QuestionPresentation.FlavorText(title: nil, body: footnoteFlavorBody)
        let resolution = try #require(model.storyResolution(for: flavorText)?.story)
        #expect(resolution.body == [
            .text("story.prose"),
            .footnote(number: 2, entry: .text("theDunwichLegacy.prologue.footnote2")),
            .text("Unsupported story entry: FootnoteEntry"),
        ])
    }
}
