@testable import ArkhamHorrorShared
import Testing

@Suite("Create game catalog")
struct GameLifecycleCreateCatalogTests {
    @Test("Night of the Zealot catalog contains campaign and three standalone scenarios")
    func nightOfTheZealotCatalogContent() {
        let catalog = CreateGameCatalog.default

        #expect(
            catalog.campaigns == [
                CreateGameCampaignOption(id: "01", title: "The Night of the Zealot"),
            ]
        )
        #expect(
            catalog.standaloneScenarios == [
                CreateGameScenarioOption(
                    id: "01104", title: "The Gathering", campaignID: "01"
                ),
                CreateGameScenarioOption(
                    id: "01120", title: "The Midnight Masks", campaignID: "01"
                ),
                CreateGameScenarioOption(
                    id: "01142", title: "The Devourer Below", campaignID: "01"
                ),
            ]
        )
    }

    @Test("Catalog display names do not expose raw server ids")
    func catalogLabelsHideRawIDs() {
        let catalog = CreateGameCatalog.default
        for campaign in catalog.campaigns {
            #expect(campaign.title != campaign.id)
            #expect(!campaign.title.contains(campaign.id))
        }
        for scenario in catalog.standaloneScenarios {
            #expect(scenario.title != scenario.id)
            #expect(!scenario.title.contains(scenario.id))
        }
    }
}
