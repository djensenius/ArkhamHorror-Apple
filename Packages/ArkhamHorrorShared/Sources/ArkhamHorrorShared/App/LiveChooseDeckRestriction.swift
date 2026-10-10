import Foundation

struct LiveChooseDeckRequiredInvestigator: Sendable, Equatable {
    let scenarioID: String
    let investigatorName: String?
    let investigatorCodes: Set<String>
}

struct LiveChooseDeckRestrictionCacheKey: Sendable, Hashable {
    let scenarioID: String?
    let isSideStory: Bool?
    let catalogRevision: String?
}

struct LiveChooseDeckRestrictionRefreshKey: Sendable, Hashable {
    let gameID: GameID
    let cacheKey: LiveChooseDeckRestrictionCacheKey
}

struct LiveChooseDeckRestrictionRefresh: Sendable {
    let id: UUID
    let task: Task<LiveChooseDeckRestrictionCheck, Error>
}

struct LiveChooseDeckRestrictionTableState: Sendable, Equatable {
    let chosenInvestigatorCodes: Set<String>?
    let isLastPlayerChoosing: Bool?

    var hasRequiredInputs: Bool {
        chosenInvestigatorCodes != nil && isLastPlayerChoosing != nil
    }

    func shouldBlockMissingRequiredInvestigator(_ requiredCodes: Set<String>) -> Bool {
        guard let chosenInvestigatorCodes, let isLastPlayerChoosing else { return false }
        return isLastPlayerChoosing && chosenInvestigatorCodes.isDisjoint(with: requiredCodes)
    }
}

struct LiveChooseDeckRestrictionTaskKey: Sendable, Equatable {
    let gameID: GameID
    let scenarioID: String?
    let catalogRevision: String?
}

struct LiveChooseDeckRestrictionContext: Sendable, Equatable {
    let rawScenarioID: String?
    let isSideStory: Bool?

    var scenarioID: String? {
        normalizedScenarioID(rawScenarioID)
    }

    /// Only a known side-story-or-unclassified scenario can have this catalog-backed
    /// rule. A campaign start asks `ChooseDeck` before any scenario exists, matching the
    /// web's `game.scenario?.id` path: no scenario id means no restriction check.
    var shouldCheckCatalog: Bool {
        rawScenarioID != nil && isSideStory != false
    }
}

enum LiveChooseDeckRestrictionCheck: Sendable, Equatable {
    case loading
    case unrestricted(scenarioID: String?)
    case unavailable(message: String, scenarioID: String?)
    case requiresInvestigator(LiveChooseDeckRequiredInvestigator)

    func notice(
        currentScenarioID: String?,
        tableState: LiveChooseDeckRestrictionTableState?
    ) -> String? {
        switch self {
        case let .unavailable(message, _):
            return message
        case .loading:
            return liveChooseDeckLocalized(
                "liveChooseDeck.restriction.checking",
                "Checking side-story deck requirements…"
            )
        case let .requiresInvestigator(requirement):
            guard normalizedScenarioID(currentScenarioID) == requirement.scenarioID else {
                return nil
            }
            let requirementMessage = Self.requirementMessage(for: requirement)
            guard tableState?.hasRequiredInputs != true else { return requirementMessage }
            return requirementMessage + "\n" + liveChooseDeckLocalized(
                "liveChooseDeck.restriction.multiplayerUnavailable",
                "Side-story investigator requirements cannot be fully checked from the current "
                    + "table state. Make sure one player uses the scenario's required investigator."
            )
        case .unrestricted:
            return nil
        }
    }

    static func requirementMessage(for requirement: LiveChooseDeckRequiredInvestigator) -> String {
        guard let investigatorName = requirement.investigatorName else {
            return liveChooseDeckLocalized(
                "liveChooseDeck.error.requiresSpecificInvestigator",
                "This scenario requires a specific investigator"
            )
        }
        return String(
            format: liveChooseDeckLocalized(
                "liveChooseDeck.error.requiresInvestigator",
                "This scenario requires %@"
            ),
            investigatorName
        )
    }

    func rejectionMessage(
        for deck: Deck,
        currentScenarioID: String?,
        tableState: LiveChooseDeckRestrictionTableState?
    ) -> String? {
        switch self {
        case .loading:
            return liveChooseDeckLocalized(
                "liveChooseDeck.restriction.checking",
                "Checking side-story deck requirements…"
            )
        case let .requiresInvestigator(requirement):
            guard normalizedScenarioID(currentScenarioID) == requirement.scenarioID else {
                return nil
            }
            let deckInvestigatorCode = deck.liveChooseDeckInvestigatorCode
            guard !requirement.investigatorCodes.contains(deckInvestigatorCode) else { return nil }
            guard tableState?.shouldBlockMissingRequiredInvestigator(
                requirement.investigatorCodes
            ) == true else { return nil }
            return Self.requirementMessage(for: requirement)
        case .unrestricted, .unavailable:
            return nil
        }
    }
}

enum LiveChooseDeckRestrictionCatalogLookup {
    static func check(
        for rawScenarioID: String?,
        in document: CampaignCatalogDocument
    ) -> LiveChooseDeckRestrictionCheck {
        guard let scenarioID = normalizedScenarioID(rawScenarioID) else {
            return .unrestricted(scenarioID: nil)
        }
        guard let sideStory = document.sideStories.first(where: {
            normalizedScenarioID($0.id) == scenarioID
        }), !sideStory.requiredInvestigatorCodes.isEmpty else {
            return .unrestricted(scenarioID: scenarioID)
        }
        return .requiresInvestigator(LiveChooseDeckRequiredInvestigator(
            scenarioID: scenarioID,
            investigatorName: sideStory.requiredInvestigator,
            investigatorCodes: Set(sideStory.requiredInvestigatorCodes.map(normalizedCardCode))
        ))
    }
}

enum LiveChooseDeckAnswerability: Sendable, Equatable {
    case canAnswer(promptKey: BasicChoicePromptKey)
    case readOnly(String)

    var promptKey: BasicChoicePromptKey? {
        switch self {
        case let .canAnswer(promptKey):
            promptKey
        case .readOnly:
            nil
        }
    }
}

extension AppModel {
    func liveChooseDeckRestrictionTableState(
        for gameID: GameID
    ) -> LiveChooseDeckRestrictionTableState? {
        guard let projection = liveGameStates[gameID]?.lastKnownProjection else { return nil }
        let chosenInvestigatorCodes = Set(
            projection.investigators.map { normalizedCardCode($0.cardCode.rawValue) }
        )
        let isLastPlayerChoosing = projection.chooseDeckPlayerIDs.map { playerIDs in
            // The server keeps every player id in IsChooseDecks for the whole phase. Match the
            // web by counting only pending ids that do not yet have a seated investigator.
            // BoardInvestigatorNode.playerID is copied from the server investigator playerId.
            playerIDs.filter { playerID in
                !projection.investigators.contains { $0.playerID == playerID }
            }.count <= 1
        }
        // If gameState is not IsChooseDecks, chooseDeckPlayerIDs is unavailable. The web's
        // empty player list makes that look like the last chooser; Apple intentionally fails
        // open because the server did not provide the ChooseDeck table data.
        return LiveChooseDeckRestrictionTableState(
            chosenInvestigatorCodes: chosenInvestigatorCodes,
            isLastPlayerChoosing: isLastPlayerChoosing
        )
    }
}

extension Deck {
    var liveChooseDeckInvestigatorCode: String {
        let fallbackCode = normalizedCardCode(playableList.investigatorCode.rawValue)
        guard let meta = playableList.meta,
              let data = meta.data(using: .utf8),
              let metadata = try? ContractJSON.decode(JSONValue.self, from: data),
              case let .object(object) = metadata,
              case let .string(alternateFront)? = object["alternate_front"],
              !alternateFront.isEmpty
        else { return fallbackCode }
        return normalizedCardCode(alternateFront)
    }
}
