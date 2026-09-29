@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("CreateGameViewModel")
struct CreateGameViewModelTests {
    @Test("Defaults create a solo Easy Night of the Zealot campaign")
    func defaultsCreateSoloCampaign() throws {
        let viewModel = CreateGameViewModel()

        #expect(viewModel.mode == .campaign)
        #expect(viewModel.selectedCampaignID == "01")
        #expect(viewModel.difficulty == .easy)
        #expect(viewModel.playerCount == 1)
        #expect(viewModel.multiplayerVariant == .solo)
        #expect(viewModel.shouldShowMultiplayerVariant == false)
        #expect(viewModel.resolvedGameName == "The Night of the Zealot")

        let request = try viewModel.makeRequest()
        #expect(request.campaignOrScenario.campaignId == "01")
        #expect(request.campaignOrScenario.scenarioId == nil)
        #expect(request.deckIds == [nil])
        #expect(request.multiplayerVariant == .solo)
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

    @Test("Player count is constrained to 1...4 and controls multiplayer variant")
    func playerCountConstrainsVariant() {
        let viewModel = CreateGameViewModel()

        viewModel.playerCount = 0
        #expect(viewModel.playerCount == 1)
        #expect(viewModel.multiplayerVariant == .solo)
        #expect(viewModel.shouldShowMultiplayerVariant == false)

        viewModel.playerCount = 3
        #expect(viewModel.playerCount == 3)
        #expect(viewModel.multiplayerVariant == .withFriends)
        #expect(viewModel.shouldShowMultiplayerVariant == true)
        #expect(viewModel.availableMultiplayerVariants == [.withFriends])

        viewModel.multiplayerVariant = .solo
        #expect(viewModel.multiplayerVariant == .withFriends)

        viewModel.playerCount = 5
        #expect(viewModel.playerCount == 4)
        #expect(viewModel.multiplayerVariant == .withFriends)

        viewModel.playerCount = 1
        #expect(viewModel.multiplayerVariant == .solo)
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
