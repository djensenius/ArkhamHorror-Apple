@testable import ArkhamHorrorShared
import Testing

@MainActor
@Suite("CreateGameViewModel mode switching")
struct CreateGameViewModelModeSwitchTests {
    @Test("Mode changes reset target-specific toggles before applying new defaults")
    func modeChangesResetTargetSpecificToggles() throws {
        let variant = CreateGameVariantOption(id: "theDreamQuest", label: "The Dream-Quest")
        let catalog = CreateGameCatalog(
            campaigns: [CreateGameCampaignOption(
                id: "06",
                title: "The Dream-Eaters",
                nameKey: nil,
                returnTo: CreateGameReturnToCampaignOption(
                    id: "56", title: "Return to The Dream-Eaters", nameKey: nil,
                    alpha: false, beta: false, dev: false
                ),
                variants: [variant]
            )],
            standaloneScenarios: [CreateGameScenarioOption(
                id: "90004", title: "Side Story", nameKey: nil, campaignID: nil,
                returnTo: CreateGameReturnToScenarioOption(
                    id: "99004", title: "Return to Side Story", nameKey: nil
                ),
                sideStoryCampaignID: "side-story-campaign",
                parts: [CreateGameSideStoryPartOption(
                    id: "90004a", title: "Part A", nameKey: nil
                )]
            )]
        )
        let viewModel = CreateGameViewModel(
            catalog: catalog,
            selectedCampaignID: "06",
            selectedScenarioID: "90004"
        )

        viewModel.useReturnTo = true
        viewModel.mode = .standaloneScenario

        #expect(viewModel.useReturnTo == false)
        #expect(viewModel.selectedVariantID == nil)

        viewModel.useReturnTo = true
        viewModel.selectedSideStoryPartID = "90004a"
        viewModel.mode = .campaign

        #expect(viewModel.useReturnTo == false)
        #expect(viewModel.selectedSideStoryPartID == nil)
        #expect(viewModel.selectedVariantID == "theDreamQuest")
        #expect(try viewModel.makeRequest().campaignOrScenario.campaignId == "06")
    }
}
