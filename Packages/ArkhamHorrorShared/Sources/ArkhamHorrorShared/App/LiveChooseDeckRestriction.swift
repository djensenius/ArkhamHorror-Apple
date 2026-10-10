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

struct LiveChooseDeckRestrictionContext: Sendable, Equatable {
    let rawScenarioID: String?
    let isSideStory: Bool?

    var scenarioID: String? {
        normalizedScenarioID(rawScenarioID)
    }

    /// A known campaign scenario cannot have a side-story required-investigator rule, so
    /// it should not show checking/unavailable copy or touch the catalog. When the board
    /// has no scenario classification yet, keep the fail-open check path so a live prompt
    /// from an older/partial payload does not silently skip a possible side-story rule.
    var shouldCheckCatalog: Bool {
        isSideStory != false
    }
}

enum LiveChooseDeckRestrictionCheck: Sendable, Equatable {
    case loading
    case unrestricted(scenarioID: String?)
    case unavailable(message: String, scenarioID: String?)
    case requiresInvestigator(LiveChooseDeckRequiredInvestigator)

    var notice: String? {
        switch self {
        case let .unavailable(message, _):
            message
        case .loading:
            liveChooseDeckLocalized(
                "liveChooseDeck.restriction.checking",
                "Checking side-story deck requirements…"
            )
        case .unrestricted, .requiresInvestigator:
            nil
        }
    }

    func rejectionMessage(for deck: Deck, currentScenarioID: String?) -> String? {
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
