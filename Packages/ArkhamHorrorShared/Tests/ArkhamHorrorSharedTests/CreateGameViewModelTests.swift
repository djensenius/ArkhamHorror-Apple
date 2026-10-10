@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("CreateGameViewModel")
// swiftlint:disable:next type_body_length
struct CreateGameViewModelTests {
    @Test("Defaults create a one-player Easy Night of the Zealot campaign")
    func defaultsCreateOnePlayerCampaign() throws {
        let viewModel = CreateGameViewModel()

        #expect(viewModel.mode == .campaign)
        #expect(viewModel.selectedCampaignID == "01")
        #expect(viewModel.difficulty == .easy)
        #expect(viewModel.playerCount == 1)
        #expect(viewModel.multiplayerVariant == .withFriends)
        #expect(viewModel.shouldShowMultiplayerVariant == false)
        #expect(viewModel.resolvedGameName == "The Night of the Zealot")

        let request = try viewModel.makeRequest()
        #expect(request.campaignOrScenario.campaignId == "01")
        #expect(request.campaignOrScenario.scenarioId == nil)
        #expect(request.deckIds == [nil, nil, nil, nil])
        #expect(request.multiplayerVariant == .withFriends)
        #expect(request.includeTarotReadings == false)
        #expect(request.options.isEmpty)
    }

    @Test("Mode switching builds standalone scenario requests from catalog selections")
    func standaloneModeBuildsScenarioRequest() throws {
        let viewModel = CreateGameViewModel()

        viewModel.mode = .standaloneScenario
        viewModel.selectedScenarioID = "01120"
        viewModel.customName = "  Masks night  "
        viewModel.difficulty = .hard

        #expect(viewModel.selectedTitle == "The Midnight Masks")
        #expect(viewModel.resolvedGameName == "Masks night")

        let request = try viewModel.makeRequest()
        #expect(request.campaignOrScenario.campaignId == nil)
        #expect(request.campaignOrScenario.scenarioId == "01120")
        #expect(request.difficulty == .hard)
        #expect(request.campaignName == "Masks night")
    }

    @Test("Invalid selections reset to the first catalog option")
    func invalidSelectionsReset() throws {
        let viewModel = CreateGameViewModel()

        viewModel.selectedCampaignID = "raw-invalid-campaign"
        viewModel.mode = .standaloneScenario
        viewModel.selectedScenarioID = "raw-invalid-scenario"

        #expect(viewModel.selectedCampaignID == "01")
        #expect(viewModel.selectedScenarioID == "01104")
        let request = try viewModel.makeRequest()
        #expect(request.campaignOrScenario.scenarioId == "01104")
    }

    @Test("Release badges expose beta before alpha for selected catalog entries")
    func releaseBadgesExposeBetaBeforeAlpha() {
        let catalog = CreateGameCatalog(
            campaigns: [CreateGameCampaignOption(
                id: "11", title: "Alpha Campaign", nameKey: nil, alpha: true, beta: true
            )],
            standaloneScenarios: [CreateGameScenarioOption(
                id: "90004", title: "Beta Scenario", nameKey: nil, campaignID: nil, beta: true
            )]
        )
        let viewModel = CreateGameViewModel(catalog: catalog, selectedCampaignID: "11")
        #expect(viewModel.selectionBadge == "Beta")
        viewModel.mode = .standaloneScenario
        #expect(viewModel.selectionBadge == "Beta")
    }

    @Test("Loading state disables submit without resetting matching choices")
    func loadingStateDisablesSubmitAndCatalogReplacementPreservesSelections() async {
        let initial = CreateGameCatalog(
            campaigns: [
                CreateGameCampaignOption(id: "01", title: "The Night of the Zealot"),
                CreateGameCampaignOption(id: "02", title: "The Dunwich Legacy"),
                CreateGameCampaignOption(id: "04", title: "The Forgotten Age"),
            ],
            standaloneScenarios: [
                CreateGameScenarioOption(
                    id: "01104", title: "The Gathering", campaignID: "01"
                ),
                CreateGameScenarioOption(
                    id: "02043", title: "Extracurricular Activity", campaignID: "02"
                ),
                CreateGameScenarioOption(
                    id: "04043", title: "The Untamed Wilds", campaignID: "04"
                ),
            ]
        )
        let replacement = CreateGameCatalog(
            campaigns: [
                CreateGameCampaignOption(id: "02", title: "The Dunwich Legacy"),
                CreateGameCampaignOption(id: "04", title: "The Forgotten Age"),
            ],
            standaloneScenarios: [
                CreateGameScenarioOption(
                    id: "02043", title: "Extracurricular Activity", campaignID: "02"
                ),
                CreateGameScenarioOption(
                    id: "04043", title: "The Untamed Wilds", campaignID: "04"
                ),
            ]
        )
        let viewModel = CreateGameViewModel(
            catalog: initial,
            isCatalogLoading: true,
            selectedCampaignID: "04",
            selectedScenarioID: "04043"
        )
        #expect(!viewModel.canSubmit)
        let submitted = await viewModel.submit { _ in
            Issue.record("Loading catalog should disable submit")
            return GameID(UUID())
        }
        #expect(submitted == nil)

        viewModel.replaceCatalog(replacement, warningMessage: nil)
        viewModel.setCatalogLoading(false)
        #expect(viewModel.selectedCampaignID == "04")
        #expect(viewModel.selectedScenarioID == "04043")
        #expect(viewModel.canSubmit)
    }

    @Test("Campaign changes reset recommended option defaults")
    func campaignChangesResetRecommendedOptionDefaults() throws {
        let sharedOption = CreateGameRecommendedOption(
            id: "PlayersDoNotControlStoryAssetClues",
            label: "Story assets",
            defaultEnabled: false,
            flag: .playersDoNotControlStoryAssetClues
        )
        let catalog = CreateGameCatalog(
            campaigns: [
                CreateGameCampaignOption(
                    id: "02", title: "The Dunwich Legacy", nameKey: nil,
                    recommendedOptions: [sharedOption]
                ),
                CreateGameCampaignOption(
                    id: "04", title: "The Forgotten Age", nameKey: nil,
                    recommendedOptions: [sharedOption]
                ),
            ],
            standaloneScenarios: []
        )
        let viewModel = CreateGameViewModel(catalog: catalog, selectedCampaignID: "02")

        viewModel.setRecommendedOption(sharedOption, enabled: true)
        #expect(try viewModel.makeRequest().options == [.flag(.playersDoNotControlStoryAssetClues)]) // swiftlint:disable:this line_length

        viewModel.selectedCampaignID = "04"

        #expect(!viewModel.isRecommendedOptionEnabled(sharedOption))
        #expect(try viewModel.makeRequest().options == [])
    }

    @Test("Unknown recommended option flags are hidden and not sent")
    func unknownRecommendedOptionsAreHiddenAndNotSent() throws {
        let known = CreateGameRecommendedOption(
            id: "PlayersDoNotControlStoryAssetClues",
            label: "Known",
            defaultEnabled: true,
            flag: .playersDoNotControlStoryAssetClues
        )
        let unknown = CreateGameRecommendedOption(
            id: "FutureOption",
            label: "Future",
            defaultEnabled: true,
            flag: nil
        )
        let catalog = CreateGameCatalog(
            campaigns: [CreateGameCampaignOption(
                id: "02", title: "The Dunwich Legacy", nameKey: nil,
                recommendedOptions: [known, unknown]
            )],
            standaloneScenarios: []
        )
        let viewModel = CreateGameViewModel(catalog: catalog, selectedCampaignID: "02")

        #expect(viewModel.selectedRecommendedOptions.map(\.id) == ["PlayersDoNotControlStoryAssetClues"]) // swiftlint:disable:this line_length
        #expect(try viewModel.makeRequest().options == [.flag(.playersDoNotControlStoryAssetClues)]) // swiftlint:disable:this line_length
    }

    @Test("Player count is constrained to 1...4 and controls multiplayer variant")
    func playerCountConstrainsVariant() {
        let viewModel = CreateGameViewModel()

        viewModel.playerCount = 0
        #expect(viewModel.playerCount == 1)
        #expect(viewModel.multiplayerVariant == .withFriends)
        #expect(viewModel.shouldShowMultiplayerVariant == false)

        viewModel.playerCount = 3
        #expect(viewModel.playerCount == 3)
        #expect(viewModel.multiplayerVariant == .withFriends)
        #expect(viewModel.shouldShowMultiplayerVariant == true)
        #expect(viewModel.availableMultiplayerVariants == [.withFriends, .solo])

        viewModel.multiplayerVariant = .solo
        #expect(viewModel.multiplayerVariant == .solo)

        viewModel.playerCount = 5
        #expect(viewModel.playerCount == 4)
        #expect(viewModel.multiplayerVariant == .solo)

        viewModel.playerCount = 1
        #expect(viewModel.multiplayerVariant == .withFriends)
    }

    @Test("Submit prevents double submit while in flight and returns the created game id")
    func submitPreventsDoubleSubmit() async {
        let viewModel = CreateGameViewModel()
        let createdID = GameID(UUID())
        let gate = CreateGameSubmitGate(createdID: createdID)

        let firstSubmit = Task { @MainActor in
            await viewModel.submit { request in
                await gate.create(request)
            }
        }
        while await gate.requestCount == 0 {
            await Task.yield()
        }
        #expect(viewModel.isSubmitting == true)

        let duplicate = await viewModel.submit { _ in
            Issue.record("Duplicate submit should not invoke createGame")
            return GameID(UUID())
        }
        #expect(duplicate == nil)
        #expect(await gate.requestCount == 1)

        await gate.resume()
        let returnedID = await firstSubmit.value
        #expect(returnedID == createdID)
        #expect(viewModel.isSubmitting == false)
        #expect(viewModel.failureMessage == nil)
    }

    @Test("Submit leaves inline failure state on create errors and clears it on later success")
    func submitFailureAndRecovery() async {
        let viewModel = CreateGameViewModel()

        let failedID = await viewModel.submit { _ in
            throw GameLifecycleError.unexpectedStatus(500)
        }
        #expect(failedID == nil)
        #expect(viewModel.isSubmitting == false)
        #expect(viewModel.failureMessage == GameLifecycleError.unexpectedStatus(500).message)

        let createdID = GameID(UUID())
        let returnedID = await viewModel.submit { _ in createdID }
        #expect(returnedID == createdID)
        #expect(viewModel.failureMessage == nil)
    }

    @Test("Submit does not call create for empty campaign catalog")
    func submitEmptyCampaignCatalog() async {
        let viewModel = CreateGameViewModel(
            catalog: CreateGameCatalog(campaigns: [], standaloneScenarios: [])
        )

        let returnedID = await viewModel.submit { _ in
            Issue.record("Invalid catalog should not call createGame")
            return GameID(UUID())
        }

        #expect(returnedID == nil)
        #expect(viewModel.isSubmitting == false)
        #expect(viewModel.failureMessage == nil)
    }

    @Test("Submit does not call create for empty standalone scenario catalog")
    func submitEmptyScenarioCatalog() async {
        let viewModel = CreateGameViewModel(
            catalog: CreateGameCatalog(campaigns: [], standaloneScenarios: [])
        )
        viewModel.mode = .standaloneScenario

        let returnedID = await viewModel.submit { _ in
            Issue.record("Invalid catalog should not call createGame")
            return GameID(UUID())
        }

        #expect(returnedID == nil)
        #expect(viewModel.isSubmitting == false)
        #expect(viewModel.failureMessage == nil)
    }

    @Test("Submit does not call create for unknown catalog selections")
    func submitUnknownSelections() async {
        let unknownCampaign = CreateGameViewModel(selectedCampaignID: "missing-campaign")
        let campaignID = await unknownCampaign.submit { _ in
            Issue.record("Unknown campaign should not call createGame")
            return GameID(UUID())
        }
        #expect(campaignID == nil)
        #expect(unknownCampaign.failureMessage == nil)

        let unknownScenario = CreateGameViewModel(
            mode: .standaloneScenario,
            selectedScenarioID: "missing-scenario"
        )
        let scenarioID = await unknownScenario.submit { _ in
            Issue.record("Unknown scenario should not call createGame")
            return GameID(UUID())
        }
        #expect(scenarioID == nil)
        #expect(unknownScenario.failureMessage == nil)
    }

    @Test("Submit cancellation clears in-flight state without showing an inline error")
    func submitCancellation() async {
        let viewModel = CreateGameViewModel()

        let returnedID = await viewModel.submit { _ in
            throw CancellationError()
        }

        #expect(returnedID == nil)
        #expect(viewModel.isSubmitting == false)
        #expect(viewModel.failureMessage == nil)
    }
}

private actor CreateGameSubmitGate {
    let createdID: GameID
    private(set) var requestCount = 0
    private var continuation: CheckedContinuation<GameID, Never>?

    init(createdID: GameID) {
        self.createdID = createdID
    }

    func create(_: CreateGameRequest) async -> GameID {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume(returning: createdID)
        continuation = nil
    }
}
