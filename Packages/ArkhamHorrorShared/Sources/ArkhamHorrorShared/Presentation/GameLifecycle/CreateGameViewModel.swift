import Foundation
import Observation

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class CreateGameViewModel {
    enum Failure: Error, Equatable, Sendable {
        case emptyCampaignCatalog
        case emptyScenarioCatalog
        case unknownCampaignSelection(String)
        case unknownScenarioSelection(String)
    }

    private(set) var catalog: CreateGameCatalog
    var catalogWarningMessage: String?

    var mode: CreateGameMode = .campaign {
        didSet { normalizeSelection() }
    }

    var selectedCampaignID: String {
        didSet {
            normalizeSelection()
            applyCampaignDefaults()
        }
    }

    var selectedScenarioID: String {
        didSet {
            normalizeSelection()
            applyScenarioDefaults()
        }
    }

    var useReturnTo = false {
        didSet { normalizeSelection() }
    }

    var selectedVariantID: String? {
        didSet { normalizeSelection() }
    }

    var recommendedOptionEnabled: [String: Bool] = [:]

    var difficulty: RequestDifficulty = .easy {
        didSet { normalizeDifficulty() }
    }

    var includeTarotReadings = false

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
        catalogWarningMessage: String? = nil,
        mode: CreateGameMode = .campaign,
        selectedCampaignID: String? = nil,
        selectedScenarioID: String? = nil
    ) {
        self.catalog = catalog
        self.catalogWarningMessage = catalogWarningMessage
        self.mode = mode
        self.selectedCampaignID = selectedCampaignID ?? catalog.campaigns.first?.id ?? ""
        self.selectedScenarioID = selectedScenarioID ?? catalog.standaloneScenarios.first?.id ?? ""
        switch mode {
        case .campaign:
            applyCampaignDefaults()
        case .standaloneScenario:
            applyScenarioDefaults()
        }
    }

    var selectedTitle: String {
        switch mode {
        case .campaign:
            if useReturnTo, let returnTo = selectedCampaign?.returnTo {
                return returnTo.title
            }
            return selectedCampaign?.title ?? gameLifecycleLocalized("create.mode.campaign", "Campaign") // swiftlint:disable:this line_length
        case .standaloneScenario:
            if useReturnTo, let returnTo = selectedScenario?.returnTo {
                return returnTo.title
            }
            return selectedScenario?.title ?? gameLifecycleLocalized(
                "create.mode.standaloneScenario", "Standalone scenario"
            )
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

    var availableDifficulties: [RequestDifficulty] {
        switch mode {
        case .campaign:
            RequestDifficulty.allCases
        case .standaloneScenario:
            selectedScenario?.difficulties ?? RequestDifficulty.allCases
        }
    }

    var canToggleReturnTo: Bool {
        switch mode {
        case .campaign:
            selectedCampaign?.returnTo != nil
        case .standaloneScenario:
            selectedScenario?.returnTo != nil
        }
    }

    var selectedCampaignVariants: [CreateGameVariantOption] {
        selectedCampaign?.variants ?? []
    }

    var selectedCampaignRecommendedOptions: [CreateGameRecommendedOption] {
        selectedCampaign?.recommendedOptions ?? []
    }

    var selectionBadge: String? {
        let alpha: Bool
        let beta: Bool
        switch mode {
        case .campaign:
            alpha = selectedCampaign?.alpha == true || (useReturnTo && selectedCampaign?.returnTo?.alpha == true) // swiftlint:disable:this line_length
            beta = selectedCampaign?.beta == true || (useReturnTo && selectedCampaign?.returnTo?.beta == true) // swiftlint:disable:this line_length
        case .standaloneScenario:
            alpha = selectedScenario?.alpha == true
            beta = selectedScenario?.beta == true
        }
        if alpha {
            return gameLifecycleLocalized("create.release.alpha", "Alpha")
        }
        if beta {
            return gameLifecycleLocalized("create.release.beta", "Beta")
        }
        return nil
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

    func replaceCatalog(_ catalog: CreateGameCatalog, warningMessage: String?) {
        self.catalog = catalog
        catalogWarningMessage = warningMessage
        selectedCampaignID = catalog.campaigns.first?.id ?? ""
        selectedScenarioID = catalog.standaloneScenarios.first?.id ?? ""
        useReturnTo = false
        selectedVariantID = nil
        recommendedOptionEnabled = [:]
        normalizeSelection()
        applyCampaignDefaults()
        applyScenarioDefaults()
    }

    func setRecommendedOption(_ option: CreateGameRecommendedOption, enabled: Bool) {
        recommendedOptionEnabled[option.id] = enabled
    }

    func isRecommendedOptionEnabled(_ option: CreateGameRecommendedOption) -> Bool {
        recommendedOptionEnabled[option.id] ?? option.defaultEnabled
    }

    func makeRequest() throws -> CreateGameRequest {
        let campaignOrScenario: CampaignOrScenario
        let effectiveCampaignID: String?
        let effectiveScenarioID: String?
        let strictAsIfAt: Bool
        switch mode {
        case .campaign:
            guard let campaign = selectedCampaign else {
                if catalog.campaigns.isEmpty {
                    throw Failure.emptyCampaignCatalog
                }
                throw Failure.unknownCampaignSelection(selectedCampaignID)
            }
            effectiveCampaignID = useReturnTo ? campaign.returnTo?.id ?? campaign.id : campaign.id
            effectiveScenarioID = nil
            strictAsIfAt = campaign.strictAsIfAtDefault
        case .standaloneScenario:
            guard let scenario = selectedScenario else {
                if catalog.standaloneScenarios.isEmpty {
                    throw Failure.emptyScenarioCatalog
                }
                throw Failure.unknownScenarioSelection(selectedScenarioID)
            }
            if let sideStoryCampaignID = scenario.sideStoryCampaignID {
                effectiveCampaignID = sideStoryCampaignID
                effectiveScenarioID = nil
            } else {
                effectiveCampaignID = nil
                effectiveScenarioID = useReturnTo ? scenario.returnTo?.id ?? scenario.id : scenario.id // swiftlint:disable:this line_length
            }
            strictAsIfAt = false
        }
        campaignOrScenario = try CampaignOrScenario(
            campaignId: effectiveCampaignID,
            scenarioId: effectiveScenarioID
        )

        return CreateGameRequest(
            deckIds: Array(repeating: nil, count: playerCount),
            playerCount: playerCount,
            campaignOrScenario: campaignOrScenario,
            difficulty: difficulty,
            campaignName: resolvedGameName,
            multiplayerVariant: multiplayerVariant,
            includeTarotReadings: includeTarotReadings,
            options: selectedCampaignOptions(),
            strictAsIfAt: .value(strictAsIfAt),
            asIfRuling: .value(strictAsIfAt ? .chapter2 : .chapter1),
            ultimatumsAndBoons: .absent,
            achievementsEnabled: .value(effectiveCampaignID != nil)
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
            failureMessage = gameLifecycleLocalized(
                "create.failure.generic", "Couldn't create game. Try again."
            )
            return nil
        }
    }

    private var selectedCampaign: CreateGameCampaignOption? {
        catalog.campaigns.first { $0.id == selectedCampaignID }
    }

    private var selectedScenario: CreateGameScenarioOption? {
        catalog.standaloneScenarios.first { $0.id == selectedScenarioID }
    }

    private func selectedCampaignOptions() -> [CampaignOption] {
        guard mode == .campaign, let campaign = selectedCampaign else { return [] }
        var options = selectedCampaignRecommendedOptions.compactMap { option -> CampaignOption? in
            guard isRecommendedOptionEnabled(option), let flag = option.flag else { return nil }
            return .flag(flag)
        }
        let variantID = selectedVariantID ?? campaign.variants.first?.id
        if let variantID, !variantID.isEmpty {
            options.append(.campaignVariant(variantID))
        }
        return options
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
        if !canToggleReturnTo, useReturnTo {
            useReturnTo = false
        }
        let selectedVariantIsAvailable = selectedVariantID.map { id in
            selectedCampaignVariants.contains { $0.id == id }
        } ?? true
        if !selectedVariantIsAvailable {
            selectedVariantID = selectedCampaignVariants.first?.id
        }
        normalizeDifficulty()
        normalizeMultiplayerVariant()
    }

    private func normalizeDifficulty() {
        guard !availableDifficulties.contains(difficulty) else { return }
        difficulty = availableDifficulties.first ?? .easy
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

    private func applyCampaignDefaults() {
        guard let campaign = selectedCampaign else {
            normalizeDifficulty()
            return
        }
        selectedVariantID = campaign.variants.first?.id
        var next: [String: Bool] = [:]
        for option in campaign.recommendedOptions {
            next[option.id] = recommendedOptionEnabled[option.id] ?? option.defaultEnabled
        }
        recommendedOptionEnabled = next
        normalizeDifficulty()
    }

    private func applyScenarioDefaults() {
        normalizeDifficulty()
    }
}
