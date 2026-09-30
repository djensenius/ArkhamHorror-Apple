import Foundation
import Observation

@MainActor
@Observable
final class CreateGameViewModel {
    enum Failure: Error, Equatable, Sendable {
        case emptyCampaignCatalog
        case emptyScenarioCatalog
        case unknownCampaignSelection(String)
        case unknownScenarioSelection(String)
    }

    let catalog: CreateGameCatalog

    var mode: CreateGameMode = .campaign {
        didSet { normalizeSelection() }
    }

    var selectedCampaignID: String {
        didSet { normalizeSelection() }
    }

    var selectedScenarioID: String {
        didSet { normalizeSelection() }
    }

    var difficulty: RequestDifficulty = .easy

    var playerCount: Int = 1 {
        didSet { normalizePlayerCount() }
    }

    var multiplayerVariant: RequestMultiplayerVariant = .withFriends {
        didSet { normalizeMultiplayerVariant() }
    }

    var customName: String = ""
    private(set) var isSubmitting = false
    private(set) var failureMessage: String?

    init(
        catalog: CreateGameCatalog = .default,
        mode: CreateGameMode = .campaign,
        selectedCampaignID: String? = nil,
        selectedScenarioID: String? = nil
    ) {
        self.catalog = catalog
        self.mode = mode
        self.selectedCampaignID = selectedCampaignID ?? catalog.campaigns.first?.id ?? ""
        self.selectedScenarioID = selectedScenarioID ?? catalog.standaloneScenarios.first?.id ?? ""
    }

    var selectedTitle: String {
        switch mode {
        case .campaign:
            selectedCampaign?.title ?? "Campaign"
        case .standaloneScenario:
            selectedScenario?.title ?? "Standalone scenario"
        }
    }

    var resolvedGameName: String {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? selectedTitle : trimmed
    }

    var shouldShowMultiplayerVariant: Bool {
        playerCount > 1
    }

    var availableMultiplayerVariants: [RequestMultiplayerVariant] {
        playerCount > 1 ? [.withFriends, .solo] : [.withFriends]
    }

    var canSubmit: Bool {
        !isSubmitting && hasValidSelection
    }

    var hasValidSelection: Bool {
        switch mode {
        case .campaign:
            selectedCampaign != nil
        case .standaloneScenario:
            selectedScenario != nil
        }
    }

    func makeRequest() throws -> CreateGameRequest {
        let campaignOrScenario: CampaignOrScenario
        switch mode {
        case .campaign:
            guard let campaign = selectedCampaign else {
                if catalog.campaigns.isEmpty {
                    throw Failure.emptyCampaignCatalog
                }
                throw Failure.unknownCampaignSelection(selectedCampaignID)
            }
            campaignOrScenario = try CampaignOrScenario(campaignId: campaign.id, scenarioId: nil)
        case .standaloneScenario:
            guard let scenario = selectedScenario else {
                if catalog.standaloneScenarios.isEmpty {
                    throw Failure.emptyScenarioCatalog
                }
                throw Failure.unknownScenarioSelection(selectedScenarioID)
            }
            campaignOrScenario = try CampaignOrScenario(campaignId: nil, scenarioId: scenario.id)
        }

        return CreateGameRequest(
            deckIds: Array(repeating: nil, count: playerCount),
            playerCount: playerCount,
            campaignOrScenario: campaignOrScenario,
            difficulty: difficulty,
            campaignName: resolvedGameName,
            multiplayerVariant: multiplayerVariant,
            includeTarotReadings: false,
            options: [],
            strictAsIfAt: .absent,
            asIfRuling: .absent,
            ultimatumsAndBoons: .absent,
            achievementsEnabled: .value(true)
        )
    }

    @discardableResult
    func submit(createGame: (CreateGameRequest) async throws -> GameID) async -> GameID? {
        guard !isSubmitting else { return nil }
        isSubmitting = true
        failureMessage = nil
        defer { isSubmitting = false }

        do {
            let request = try makeRequest()
            return try await createGame(request)
        } catch is CancellationError {
            return nil
        } catch let error as GameLifecycleError {
            failureMessage = error.message
            return nil
        } catch {
            failureMessage = "Couldn't create game. Try again."
            return nil
        }
    }

    private var selectedCampaign: CreateGameCampaignOption? {
        catalog.campaigns.first { $0.id == selectedCampaignID }
    }

    private var selectedScenario: CreateGameScenarioOption? {
        catalog.standaloneScenarios.first { $0.id == selectedScenarioID }
    }

    private func normalizeSelection() {
        if !catalog.campaigns.contains(where: { $0.id == selectedCampaignID }) {
            let fallback = catalog.campaigns.first?.id ?? ""
            if selectedCampaignID != fallback {
                selectedCampaignID = fallback
            }
        }
        if !catalog.standaloneScenarios.contains(where: { $0.id == selectedScenarioID }) {
            let fallback = catalog.standaloneScenarios.first?.id ?? ""
            if selectedScenarioID != fallback {
                selectedScenarioID = fallback
            }
        }
        normalizeMultiplayerVariant()
    }

    private func normalizePlayerCount() {
        let clamped = min(max(playerCount, 1), 4)
        if playerCount != clamped {
            playerCount = clamped
            return
        }
        if playerCount == 1 {
            multiplayerVariant = .withFriends
        }
    }

    private func normalizeMultiplayerVariant() {
        if playerCount == 1, multiplayerVariant != .withFriends {
            multiplayerVariant = .withFriends
        }
    }
}
