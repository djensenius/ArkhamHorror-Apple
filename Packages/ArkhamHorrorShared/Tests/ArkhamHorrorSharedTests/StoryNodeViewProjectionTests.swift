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
}
