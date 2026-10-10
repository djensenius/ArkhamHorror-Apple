import Foundation

struct LiveChooseDeckRequiredInvestigator: Sendable, Equatable {
    let scenarioID: String
    let investigatorName: String?
    let investigatorCodes: Set<String>
}

struct LiveChooseDeckRestrictionCacheKey: Sendable, Equatable {
    let scenarioID: String?
    let isSideStory: Bool?
    let catalogRevision: String?
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

    func notice(tableState: LiveChooseDeckRestrictionTableState?) -> String? {
        switch self {
        case let .unavailable(message, _):
            message
        case .loading:
            liveChooseDeckLocalized(
                "liveChooseDeck.restriction.checking",
                "Checking side-story deck requirements…"
            )
        case .requiresInvestigator where tableState?.hasRequiredInputs != true:
            liveChooseDeckLocalized(
                "liveChooseDeck.restriction.multiplayerUnavailable",
                "Side-story investigator requirements cannot be fully checked from the current table state. Make sure one player uses the scenario's required investigator."
            )
        case .unrestricted, .requiresInvestigator:
            nil
        }
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
