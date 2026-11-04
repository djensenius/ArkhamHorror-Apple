@testable import ArkhamHorrorShared
import SwiftUI
import Testing

@MainActor
@Suite("Story node view projections")
struct StoryNodeViewProjectionTests {
    @Test("Wrapping row layout returns finite measured widths for unconstrained proposals")
    func wrappingRowLayoutUsesMeasuredWidthForUnconstrainedProposals() {
        let measuredWidth = CGFloat(248)

        let infinityWidth = StoryCenteredWrappingRowLayout.resolvedWidth(
            for: .infinity,
            measuredWidth: measuredWidth
        )
        #expect(infinityWidth == measuredWidth)
        #expect(infinityWidth.isFinite)

        let unspecifiedWidth = StoryCenteredWrappingRowLayout.resolvedWidth(
            for: .unspecified,
            measuredWidth: measuredWidth
        )
        #expect(unspecifiedWidth == measuredWidth)
        #expect(unspecifiedWidth.isFinite)
    }

    @Test("Encounter sets group for wrapping and entry statuses use neutral labels")
    func encounterSetGroupingAndStatusSemantics() {
        let devourer = StoryAssetReference(
            role: .encounterSet,
            assetPath: "encounter-sets/the-devourer-below.png",
            alt: nil
        )
        let ancientEvils = StoryAssetReference(
            role: .encounterSet,
            assetPath: "encounter-sets/ancient-evils.png",
            alt: nil
        )
        let groupChildren: [StoryNode] = [.image(devourer), .image(ancientEvils)]

        #expect(StoryNodePresentation.encounterSetGroupReferences(groupChildren) == [
            devourer, ancientEvils,
        ])
        #expect(StoryNodePresentation.encounterSetGroupReferences(
            [.text("Gather "), .image(devourer)]
        ) == nil)
        #expect(StoryFlavorEntryStatus.status(for: [.invalidEntry]) == .invalid)
        #expect(StoryFlavorEntryStatus.status(for: [.validEntry]) == .valid)
        #expect(StoryFlavorEntryStatus.status(for: [.redEntry]) == nil)
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("en") {
            #expect(StoryFlavorEntryStatus.invalid.accessibilityLabel == "Invalid")
        }
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("de") {
            #expect(StoryFlavorEntryStatus.valid.accessibilityLabel == "Gültig")
            #expect(StoryFlavorEntryStatus.invalid.accessibilityLabel == "Ungültig")
        }
    }

    @Test("A footnote body projects a caption-relative raised number and one localized label")
    func footnoteEntryProjectsMarkerAndLocalizedLabel() {
        let body: ResolvedStoryEntry = .nodes([
            .text("Olaus Wormius, "),
            .emphasis(.italic, [.text("Necronomicon")]),
            .footnoteMarker("3"),
            .text("."),
        ])
        var requestedStyles: [StoryInlineTextStyle] = []
        let presentation = CampaignPromptLocalization.$localizationIdentifierOverride
            .withValue("en") {
                StoryFootnoteEntryPresentation(
                    number: 2, entry: body, dynamicTypeSize: .large
                ) { style, _ in
                    requestedStyles.append(style)
                    return 12
                }
            }
        #expect(requestedStyles == [.caption])
        #expect(presentation.marker == StoryFootnoteMarkerRun(
            number: "2", pointSize: 12 * 0.7, baselineOffset: 12 / 3
        ))
        #expect(
            presentation.accessibilityLabel
                == "Footnote 2: Olaus Wormius, Necronomicon footnote 3."
        )
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("de") {
            #expect(
                StoryFootnoteEntryPresentation(
                    number: 11, entry: .text("Armitage"), dynamicTypeSize: .large
                ) { _, _ in 12 }.accessibilityLabel == "Fußnote 11: Armitage"
            )
        }
    }

    @Test("A footnote label speaks every resolved body shape the view shows")
    func footnoteSpokenTextCoversNestedBodies() {
        let body: ResolvedStoryEntry = .composite(entries: [
            .modified(modifiers: [.blueEntry], entry: .text(" Lead ")),
            .list(items: [ResolvedStoryListItem(
                entry: .text("Item"),
                nested: [
                    ResolvedStoryListItem(entry: .tarotReference(arcana: "TheFool0"), nested: []),
                ]
            )]),
            .divider,
            .chaosTokenMorph(from: .skull, target: .cultist),
        ])
        #expect(
            StoryFootnoteEntryPresentation.spokenText(for: body, cardCatalog: nil)
                == "Lead Item Tarot TheFool0 Chaos token Skull to Cultist"
        )
    }

    @Test("The footnote accessibility label exists in the English and German bundles")
    func footnoteAccessibilityLabelIsLocalized() throws {
        let expected = [
            "en": #""story.footnote.accessibilityLabel" = "Footnote %d: %@";"#,
            "de": #""story.footnote.accessibilityLabel" = "Fußnote %d: %@";"#,
        ]
        let localization = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/ArkhamHorrorShared/Localization")
        for (language, line) in expected {
            let strings = try String(
                contentsOf: localization.appending(path: "\(language).lproj/Localizable.strings"),
                encoding: .utf8
            )
            #expect(strings.contains(line))
        }
    }
}
