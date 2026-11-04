@testable import ArkhamHorrorShared
import Foundation
import Testing

/// TASK-1.22.13: a catalog choice label wrapped in `<p>` / `<hN>` that has web icons but
/// no `[^N]` marker must arrive inline, since the inline label renderer rejects blocks.
@Suite("Story catalog wrapped icon choice labels")
struct StoryCatalogWrappedIconLabelTests {
    private static func resolver() async throws -> LocaleCatalogResolver {
        try await StoryCatalogInlineMarkupTests.resolver(
            entryKeys: [
                "label.paragraphIcon", "label.headingIcon", "label.inlineIcon",
                "label.paragraphPlain",
            ],
            chunkEntries: """
            {"label.paragraphIcon":{"form":"message","nodes":[\
            {"type":"paragraph","styles":[],"children":[{"type":"text","value":" Spend "},\
            {"type":"var","name":"action","source":"named","role":"icon"},\
            {"type":"text","value":" at the gate "}]}],\
            "variables":[{"name":"action","source":"named","role":"icon"}]},\
            "label.headingIcon":{"form":"message","nodes":[\
            {"type":"heading","level":2,"styles":[],"children":[{"type":"text","value":"Seal "},\
            {"type":"emphasis","style":"italic","children":[\
            {"type":"var","name":"runeM","source":"named","role":"icon"}]}]}],\
            "variables":[{"name":"runeM","source":"named","role":"icon"}]},\
            "label.inlineIcon":{"form":"message","nodes":[\
            {"type":"text","value":" Spend "},\
            {"type":"var","name":"action","source":"named","role":"icon"},\
            {"type":"text","value":" at the gate "}],\
            "variables":[{"name":"action","source":"named","role":"icon"}]},\
            "label.paragraphPlain":{"form":"message","nodes":[\
            {"type":"paragraph","styles":[],"children":[\
            {"type":"text","value":" Read the "},\
            {"type":"emphasis","style":"italic","children":[{"type":"text","value":"book"}]}\
            ]}],"variables":[]}}
            """
        )
    }

    private static func label(
        _ key: String, _ resolver: LocaleCatalogResolver
    ) throws -> BasicChoiceResolvedLabelText {
        try StoryNarrativeLocalization.resolveProductionChoiceLabelRich(
            key, resolver: resolver, catalogUnavailability: .catalog(.transportFailure)
        ).get()
    }

    @Test("Paragraph- and heading-wrapped icon choice labels without a marker render inline")
    func wrappedIconChoiceLabelsRenderInline() async throws {
        let resolver = try await Self.resolver()
        let cases: [(String, BasicChoiceResolvedLabelText)] = [
            ("$label.paragraphIcon", BasicChoiceResolvedLabelText(
                title: "Spend action at the gate",
                inlineNodes: [.text("Spend "), .icon("action"), .text(" at the gate")]
            )),
            ("$label.headingIcon", BasicChoiceResolvedLabelText(
                title: "Seal rune m",
                inlineNodes: [.text("Seal "), .emphasis(.italic, [.icon("rune-M")])]
            )),
        ]
        for (key, expected) in cases {
            let label = try Self.label(key, resolver)
            #expect(label == expected, Comment(rawValue: key))
            #expect(StoryInlineTextRenderer.text(
                for: label.inlineNodes ?? [.paragraph([])], textStyle: .body
            ) != nil, Comment(rawValue: key))
        }
    }

    @Test("Unwrapped icon labels and icon-less, marker-less wrapped labels are unchanged")
    func unwrappedAndPlainLabelsAreUnchanged() async throws {
        let resolver = try await Self.resolver()
        #expect(try Self.label("$label.inlineIcon", resolver) == BasicChoiceResolvedLabelText(
            title: "Spend action at the gate",
            inlineNodes: [.text("Spend "), .icon("action"), .text(" at the gate")]
        ))
        // Without icons or a marker the label keeps its plain title and no inline nodes.
        #expect(try Self.label("$label.paragraphPlain", resolver) == BasicChoiceResolvedLabelText(
            title: "Read the book"
        ))
    }
}
