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

    @Test("ReturnToEntry projects the web return-to wash values and no status marker")
    func returnToEntryPresentationValues() {
        #expect(StoryReturnToEntryPresentation.applies(to: [.returnToEntry]))
        #expect(StoryReturnToEntryPresentation.applies(to: [.borderedEntry, .returnToEntry]))
        #expect(!StoryReturnToEntryPresentation.applies(to: [.borderedEntry]))
        #expect(!StoryReturnToEntryPresentation.applies(to: []))
        // Codex drops Return to, as the web's FormattedEntry does.
        #expect(!StoryReturnToEntryPresentation.applies(to: [.codexEntry, .returnToEntry]))
        #expect(StoryReturnToEntryPresentation.colorHex == 0x2D6A62)
        #expect(StoryReturnToEntryPresentation.ruleWidth == 3)
        #expect(StoryReturnToEntryPresentation.leadingInset == 10)
        // Text starts 13 from the edge: 10 clear of the 3pt rule, matching the web.
        #expect(StoryReturnToEntryPresentation.effectiveLeadingPadding == 13)
        #expect(StoryReturnToEntryPresentation.verticalInset == 2)
        #expect(StoryReturnToEntryPresentation.washOpacity == 0.10)
        #expect(StoryReturnToEntryPresentation.washEnd == 0.75)
        #expect(StoryReturnToEntryPresentation.trailingRadius == 4)
        #expect(StoryFlavorEntryStatus.status(for: [.returnToEntry]) == nil)
    }

    @Test("The Return to rule keeps #2d6a62 in light mode and clears 3:1 on dark story backgrounds")
    func returnToRuleContrast() {
        let light = StoryReturnToEntryPresentation.colorHex
        let dark = StoryReturnToEntryPresentation.darkColorHex
        #expect(light == 0x2D6A62)
        #expect(dark == 0x4A9E92)

        let lightRatio = ArkhamColorContrast.contrastRatio(light, 0xFFFFFF)
        #expect(abs(lightRatio - 6.27) < 0.01)
        #expect(lightRatio >= ArkhamColorContrast.minimumNonTextRatio)

        // macOS dark window, macOS dark control/sidebar grey, and the story gradient start.
        let darkBackgrounds: [UInt32: Double] = [0x1E1E1E: 5.24, 0x323232: 4.03, 0x0A1217: 5.93]
        for (background, expected) in darkBackgrounds {
            let ratio = ArkhamColorContrast.contrastRatio(dark, background)
            #expect(abs(ratio - expected) < 0.01, "background \(String(background, radix: 16))")
            #expect(ratio >= ArkhamColorContrast.minimumNonTextRatio)
        }
    }

    @Test("WCAG contrast ratio matches the reference black/white and grey values")
    func wcagContrastRatio() {
        #expect(ArkhamColorContrast.relativeLuminance(0x000000) == 0)
        #expect(ArkhamColorContrast.relativeLuminance(0xFFFFFF) == 1)
        #expect(ArkhamColorContrast.contrastRatio(0x000000, 0xFFFFFF) == 21)
        #expect(ArkhamColorContrast.contrastRatio(0xFFFFFF, 0x000000) == 21)
        #expect(abs(ArkhamColorContrast.contrastRatio(0x777777, 0xFFFFFF) - 4.48) < 0.01)
        #expect(ArkhamColorContrast.contrastRatio(0x2D6A62, 0x2D6A62) == 1)
    }

    @Test("Return to sits inside framed panels and outside unframed washes; codex ignores it")
    func returnToPanelLayering() {
        // Innermost first.
        #expect(StoryFlavorPanelLayout.layers(for: [.returnToEntry]) == [.surface, .returnTo])
        #expect(StoryFlavorPanelLayout.layers(for: [.byDifficultyEntry, .returnToEntry])
            == [.surface, .returnTo])
        #expect(StoryFlavorPanelLayout.layers(for: [.returnToEntry, .validEntry])
            == [.surface, .returnTo])
        #expect(StoryFlavorPanelLayout.layers(for: [.borderedEntry, .returnToEntry])
            == [.returnTo, .surface])
        #expect(StoryFlavorPanelLayout.layers(for: [.interludeEntry, .returnToEntry])
            == [.returnTo, .surface])
        #expect(StoryFlavorPanelLayout.layers(for: [.codexEntry, .returnToEntry]) == [.surface])
        #expect(StoryFlavorPanelLayout.layers(for: [.borderedEntry]) == [.surface])
        #expect(StoryFlavorPanelLayout.layers(for: []) == [.surface])
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

    @Test("A footnote label keeps nested valid and invalid entry statuses in place")
    func footnoteSpokenTextKeepsNestedEntryStatus() {
        let body: ResolvedStoryEntry = .list(items: [ResolvedStoryListItem(
            entry: .modified(modifiers: [.validEntry], entry: .text("Seal the gate")),
            nested: [ResolvedStoryListItem(
                entry: .columns(entries: [
                    .modified(modifiers: [.invalidEntry, .redEntry], entry: .text("Burn it")),
                    .text("Flee"),
                ]),
                nested: []
            )]
        )])
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("en") {
            #expect(
                StoryFootnoteEntryPresentation.spokenText(for: body, cardCatalog: nil)
                    == "Valid Seal the gate Invalid Burn it Flee"
            )
        }
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("de") {
            #expect(
                StoryFootnoteEntryPresentation.spokenText(for: body, cardCatalog: nil)
                    == "Gültig Seal the gate Ungültig Burn it Flee"
            )
        }
    }

    @Test("Nested story entries default to body metrics; a footnote body uses caption metrics")
    func footnoteNestedEntriesUseCaptionInlineStyle() {
        #expect(EnvironmentValues().storyEntryInlineTextStyle == .body)
        var footnoteEnvironment = EnvironmentValues()
        footnoteEnvironment.storyEntryInlineTextStyle = StoryFootnoteEntryPresentation.textStyle
        #expect(footnoteEnvironment.storyEntryInlineTextStyle == .caption)
        let bodyMarker = StoryFootnoteMarkerMetrics.run(
            "3", textStyle: .body, dynamicTypeSize: .large
        )
        let captionMarker = StoryFootnoteMarkerMetrics.run(
            "3", textStyle: .caption, dynamicTypeSize: .large
        )
        #expect(captionMarker.pointSize < bodyMarker.pointSize)
        #expect(
            StoryWebGlyphFontMetrics.pointSize(forIconNamed: "elderSign", textStyle: .caption)
                < StoryWebGlyphFontMetrics.pointSize(forIconNamed: "elderSign", textStyle: .body)
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
