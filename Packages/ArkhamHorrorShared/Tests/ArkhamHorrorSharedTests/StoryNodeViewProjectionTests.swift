@testable import ArkhamHorrorShared
import Testing

@MainActor
@Suite("Story node view projections")
struct StoryNodeViewProjectionTests {
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
        #expect(StoryFlavorEntryStatus.invalid.accessibilityLabel == "Invalid")
        CampaignPromptLocalization.$localizationIdentifierOverride.withValue("de") {
            #expect(StoryFlavorEntryStatus.valid.accessibilityLabel == "Gültig")
            #expect(StoryFlavorEntryStatus.invalid.accessibilityLabel == "Ungültig")
        }
    }
}
