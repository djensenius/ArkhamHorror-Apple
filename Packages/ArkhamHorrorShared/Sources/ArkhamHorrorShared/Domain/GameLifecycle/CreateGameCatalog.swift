import Foundation

/// Option-driven native create-game catalog entries. Wire identifiers stay here, behind
/// display names, so the creation UI never asks a player to type or read raw server IDs.
struct CreateGameCatalog: Sendable, Equatable {
    let catalogRevision: String?
    let campaigns: [CreateGameCampaignOption]
    /// Campaign scenarios that can be created as standalone games, standalone scenarios and
    /// side stories. This mirrors the web flow's create-request behavior cited in
    /// `frontend/src/arkham/views/NewCampaign.vue:352-380`.
    let standaloneScenarios: [CreateGameScenarioOption]

    init(
        catalogRevision: String? = nil,
        campaigns: [CreateGameCampaignOption],
        standaloneScenarios: [CreateGameScenarioOption]
    ) {
        self.catalogRevision = catalogRevision
        self.campaigns = campaigns
        self.standaloneScenarios = standaloneScenarios
    }

    static let nightOfTheZealotCampaign = CreateGameCampaignOption(
        id: "01", title: "The Night of the Zealot", nameKey: nil
    )

    static let nightOfTheZealotScenarios: [CreateGameScenarioOption] = [
        CreateGameScenarioOption(
            id: "01104", title: "The Gathering", nameKey: nil, campaignID: nightOfTheZealotCampaign.id // swiftlint:disable:this line_length
        ),
        CreateGameScenarioOption(
            id: "01120", title: "The Midnight Masks", nameKey: nil,
            campaignID: nightOfTheZealotCampaign.id
        ),
        CreateGameScenarioOption(
            id: "01142", title: "The Devourer Below", nameKey: nil,
            campaignID: nightOfTheZealotCampaign.id
        ),
    ]

    static let nightOfTheZealot = CreateGameCatalog(
        campaigns: [nightOfTheZealotCampaign],
        standaloneScenarios: nightOfTheZealotScenarios
    )

    static let `default` = nightOfTheZealot
}

struct CreateGameCampaignOption: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let title: String
    let nameKey: String?
    let alpha: Bool
    let beta: Bool
    let returnTo: CreateGameReturnToCampaignOption?
    let variants: [CreateGameVariantOption]
    let recommendedOptions: [CreateGameRecommendedOption]
    let strictAsIfAtDefault: Bool

    init(id: String, title: String) {
        self.init(id: id, title: title, nameKey: nil)
    }

    init(
        id: String,
        title: String,
        nameKey: String?,
        alpha: Bool = false,
        beta: Bool = false,
        returnTo: CreateGameReturnToCampaignOption? = nil,
        variants: [CreateGameVariantOption] = [],
        recommendedOptions: [CreateGameRecommendedOption] = [],
        strictAsIfAtDefault: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.nameKey = nameKey
        self.alpha = alpha
        self.beta = beta
        self.returnTo = returnTo
        self.variants = variants
        self.recommendedOptions = recommendedOptions
        self.strictAsIfAtDefault = strictAsIfAtDefault ?? Self.defaultStrictAsIfAt(for: id)
    }

    private static func defaultStrictAsIfAt(for id: String) -> Bool {
        // Mirrors the web chapter rule in `frontend/src/arkham/data.ts:48-53`: official
        // campaigns from `11` on use Chapter 2 rules; homebrew/unknown ids default to Chapter 1.
        guard !id.hasPrefix(":"), id >= "11" else { return false }
        return true
    }
}

struct CreateGameReturnToCampaignOption: Sendable, Equatable, Hashable {
    let id: String
    let title: String
    let nameKey: String?
    let alpha: Bool
    let beta: Bool
}

struct CreateGameScenarioOption: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let title: String
    let nameKey: String?
    let campaignID: String?
    let alpha: Bool
    let beta: Bool
    let returnTo: CreateGameReturnToScenarioOption?
    let difficulties: [RequestDifficulty]
    let requiredInvestigator: String?
    let requiredInvestigatorCodes: [String]
    /// A side story with multiple scenarios starts as a campaign on the web when the
    /// "both scenarios" mode is selected (`NewCampaign.vue:358-365`). This field is the
    /// campaign id to echo in that request while sending `scenarioId: null`.
    let sideStoryCampaignID: String?
    let parts: [CreateGameSideStoryPartOption]

    init(id: String, title: String, campaignID: String?) {
        self.init(id: id, title: title, nameKey: nil, campaignID: campaignID)
    }

    init(
        id: String,
        title: String,
        nameKey: String?,
        campaignID: String?,
        alpha: Bool = false,
        beta: Bool = false,
        returnTo: CreateGameReturnToScenarioOption? = nil,
        difficulties: [RequestDifficulty] = RequestDifficulty.allCases,
        requiredInvestigator: String? = nil,
        requiredInvestigatorCodes: [String] = [],
        sideStoryCampaignID: String? = nil,
        parts: [CreateGameSideStoryPartOption] = []
    ) {
        self.id = id
        self.title = title
        self.nameKey = nameKey
        self.campaignID = campaignID
        self.alpha = alpha
        self.beta = beta
        self.returnTo = returnTo
        self.difficulties = difficulties.isEmpty ? RequestDifficulty.allCases : difficulties
        self.requiredInvestigator = requiredInvestigator
        self.requiredInvestigatorCodes = requiredInvestigatorCodes
        self.sideStoryCampaignID = sideStoryCampaignID
        self.parts = parts
    }
}

struct CreateGameReturnToScenarioOption: Sendable, Equatable, Hashable {
    let id: String
    let title: String
    let nameKey: String?
}

struct CreateGameSideStoryPartOption: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let title: String
    let nameKey: String?
}

struct CreateGameVariantOption: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let label: String
}

struct CreateGameRecommendedOption: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let label: String
    let defaultEnabled: Bool
    let flag: CampaignOptionFlag?
}

enum CreateGameMode: String, CaseIterable, Identifiable, Sendable, Equatable, Hashable {
    case campaign
    case standaloneScenario

    var id: Self {
        self
    }

    var displayName: String {
        switch self {
        case .campaign:
            gameLifecycleLocalized("create.mode.campaign", "Campaign")
        case .standaloneScenario:
            gameLifecycleLocalized("create.mode.standaloneScenario", "Standalone scenario")
        }
    }
}

extension RequestDifficulty {
    var displayName: String {
        switch self {
        case .easy:
            gameLifecycleLocalized("create.difficulty.easy", "Easy")
        case .standard:
            gameLifecycleLocalized("create.difficulty.standard", "Standard")
        case .hard:
            gameLifecycleLocalized("create.difficulty.hard", "Hard")
        case .expert:
            gameLifecycleLocalized("create.difficulty.expert", "Expert")
        }
    }
}

extension RequestMultiplayerVariant {
    var displayName: String {
        switch self {
        case .solo:
            gameLifecycleLocalized("create.multiplayer.solo", "Multihanded Solo")
        case .withFriends:
            gameLifecycleLocalized("create.multiplayer.withFriends", "With Friends")
        }
    }
}

extension CreateGameCatalog {
    static func from(
        document: CampaignCatalogDocument,
        resolver: LocaleCatalogResolver?
    ) -> CreateGameCatalog {
        let campaigns = document.campaigns.map { campaign in
            CreateGameCampaignOption(
                id: campaign.id,
                title: Self.resolveTitle(campaign.nameKey, resolver: resolver),
                nameKey: campaign.nameKey,
                alpha: campaign.alpha,
                beta: campaign.beta,
                returnTo: campaign.returnTo.map { returnTo in
                    CreateGameReturnToCampaignOption(
                        id: returnTo.id,
                        title: Self.resolveTitle(returnTo.nameKey, resolver: resolver),
                        nameKey: returnTo.nameKey,
                        alpha: returnTo.alpha,
                        beta: returnTo.beta
                    )
                },
                variants: campaign.variants.map { variant in
                    let key = "create.fullCampaignOption.\(variant.key)"
                    return CreateGameVariantOption(
                        id: variant.key,
                        label: Self.resolveTitle(key, resolver: resolver)
                    )
                },
                recommendedOptions: campaign.recommendedOptions.map { option in
                    let key = "create.recommendedOption.\(option.tag).title"
                    return CreateGameRecommendedOption(
                        id: option.tag,
                        label: Self.resolveTitle(key, resolver: resolver),
                        defaultEnabled: option.defaultEnabled,
                        flag: CampaignOptionFlag(rawValue: option.tag)
                    )
                }
            )
        }

        let campaignScenarios = document.scenarios.map { scenario in
            scenarioOption(from: scenario, resolver: resolver, isSideStory: false)
        }
        let sideStories = document.sideStories.map { scenario in
            scenarioOption(from: scenario, resolver: resolver, isSideStory: true)
        }
        return CreateGameCatalog(
            catalogRevision: document.catalogRevision,
            campaigns: campaigns,
            standaloneScenarios: campaignScenarios + sideStories
        )
    }

    private static func scenarioOption(
        from scenario: CampaignCatalogScenario,
        resolver: LocaleCatalogResolver?,
        isSideStory: Bool
    ) -> CreateGameScenarioOption {
        CreateGameScenarioOption(
            id: scenario.id,
            title: resolveTitle(scenario.nameKey, resolver: resolver),
            nameKey: scenario.nameKey,
            campaignID: isSideStory ? nil : scenario.campaignID,
            alpha: scenario.alpha,
            beta: scenario.beta,
            returnTo: zipOptionals(scenario.returnToID, scenario.returnToNameKey).map { id, nameKey in // swiftlint:disable:this line_length
                CreateGameReturnToScenarioOption(
                    id: id,
                    title: Self.resolveTitle(nameKey, resolver: resolver),
                    nameKey: nameKey
                )
            },
            difficulties: scenario.standaloneDifficulties,
            requiredInvestigator: scenario.requiredInvestigator,
            requiredInvestigatorCodes: scenario.requiredInvestigatorCodes,
            sideStoryCampaignID: isSideStory ? scenario.campaignID : nil,
            parts: scenario.parts.map { part in
                CreateGameSideStoryPartOption(
                    id: part.id,
                    title: Self.resolveTitle(part.nameKey, resolver: resolver),
                    nameKey: part.nameKey
                )
            }
        )
    }

    private static func resolveTitle(_ key: String, resolver: LocaleCatalogResolver?) -> String {
        guard let resolver else { return key }
        switch resolver.render(key: key, variables: .object([:])) {
        case let .success(nodes):
            let text = nodes.map(\.plainText).joined().trimmingCharacters(in: .whitespacesAndNewlines) // swiftlint:disable:this line_length
            return text.isEmpty ? key : text
        case .failure:
            return key
        }
    }

    private static func zipOptionals<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
        guard let first, let second else { return nil }
        return (first, second)
    }
}
