// swiftlint:disable file_length
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
    let dev: Bool
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
        dev: Bool = false,
        returnTo: CreateGameReturnToCampaignOption? = nil,
        variants: [CreateGameVariantOption] = [],
        recommendedOptions: [CreateGameRecommendedOption] = [],
        strictAsIfAtDefault: Bool? = nil,
        chapter: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.nameKey = nameKey
        self.alpha = alpha
        self.beta = beta
        self.dev = dev
        self.returnTo = returnTo
        self.variants = variants
        self.recommendedOptions = recommendedOptions
        self.strictAsIfAtDefault = strictAsIfAtDefault ?? Self.defaultStrictAsIfAt(
            for: id, chapter: chapter
        )
    }

    static func defaultStrictAsIfAt(for id: String, chapter: Int? = nil) -> Bool {
        // Mirrors the web chapter rule in `frontend/src/arkham/data.ts:48-53`: an explicit
        // campaign chapter wins; otherwise official campaigns from `11` on use Chapter 2
        // rules and homebrew/unknown ids default to Chapter 1.
        if let chapter {
            return chapter == 2
        }
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
    let dev: Bool
}

struct CreateGameScenarioOption: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let title: String
    let nameKey: String?
    let campaignID: String?
    let alpha: Bool
    let beta: Bool
    let dev: Bool
    let returnTo: CreateGameReturnToScenarioOption?
    let returnToVariant: Bool
    let difficulties: [RequestDifficulty]
    let requiredInvestigator: String?
    let requiredInvestigatorCodes: [String]
    let deckRequirements: [String]
    let recommendedOptions: [CreateGameRecommendedOption]
    let strictAsIfAtDefault: Bool
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
        dev: Bool = false,
        returnTo: CreateGameReturnToScenarioOption? = nil,
        returnToVariant: Bool = false,
        difficulties: [RequestDifficulty] = RequestDifficulty.allCases,
        requiredInvestigator: String? = nil,
        requiredInvestigatorCodes: [String] = [],
        deckRequirements: [String] = [],
        recommendedOptions: [CreateGameRecommendedOption] = [],
        strictAsIfAtDefault: Bool = false,
        sideStoryCampaignID: String? = nil,
        parts: [CreateGameSideStoryPartOption] = []
    ) {
        self.id = id
        self.title = title
        self.nameKey = nameKey
        self.campaignID = campaignID
        self.alpha = alpha
        self.beta = beta
        self.dev = dev
        self.returnTo = returnTo
        self.returnToVariant = returnToVariant
        self.difficulties = difficulties
        self.requiredInvestigator = requiredInvestigator
        self.requiredInvestigatorCodes = requiredInvestigatorCodes
        self.deckRequirements = deckRequirements
        self.recommendedOptions = recommendedOptions
        self.strictAsIfAtDefault = strictAsIfAtDefault
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

private struct CreateGameDisplayRules {
    let includeBeta: Bool
    let includeAlpha = false
    let includeDev = false

    func shouldDisplay(alpha: Bool, beta: Bool, dev: Bool) -> Bool {
        if dev {
            return includeDev && includeAlpha
        }
        if beta {
            return includeBeta
        }
        if alpha {
            return includeAlpha
        }
        return true
    }
}

extension CreateGameCatalog {
    static func from(
        document: CampaignCatalogDocument,
        resolver: LocaleCatalogResolver?,
        includeBeta: Bool = false
    ) -> CreateGameCatalog {
        // Native has no `?alpha` opt-in. Match the web's `filterDisplayable` policy with
        // alpha/dev disabled; dev entries would require both a dev build and alpha opt-in.
        let displayRules = CreateGameDisplayRules(includeBeta: includeBeta)
        let campaignOptionsByID = Dictionary(
            uniqueKeysWithValues: document.campaigns
                .filter { displayRules.shouldDisplay(alpha: $0.alpha, beta: $0.beta, dev: $0.dev) }
                .map { campaign in
                    let option = campaignOption(
                        from: campaign,
                        resolver: resolver,
                        displayRules: displayRules
                    )
                    return (campaign.id, option)
                }
        )
        let campaigns = document.campaigns.compactMap { campaignOptionsByID[$0.id] }

        let campaignScenarios = document.scenarios
            // Mirrors `frontend/src/arkham/views/NewCampaign.vue:118-129`: hidden scenarios,
            // non-standalone scenarios, hidden parent campaigns and The Scarlet Keys campaign
            // are not reachable as individual standalone scenarios.
            .filter { $0.show && $0.standalone }
            .filter { $0.campaignID != "09" }
            .filter { scenario in
                guard displayRules.shouldDisplay(
                    alpha: scenario.alpha, beta: scenario.beta, dev: scenario.dev
                ) else { return false }
                guard let campaignID = scenario.campaignID else { return true }
                return campaignOptionsByID[campaignID] != nil
            }
            .map { scenario in
                scenarioOption(
                    from: scenario,
                    resolver: resolver,
                    isSideStory: false,
                    parentCampaign: scenario.campaignID.flatMap { campaignOptionsByID[$0] }
                )
            }
        let sideStories = document.sideStories
            .filter { displayRules.shouldDisplay(alpha: $0.alpha, beta: $0.beta, dev: $0.dev) }
            .map { scenario in
                scenarioOption(
                    from: scenario,
                    resolver: resolver,
                    isSideStory: true,
                    parentCampaign: scenario.campaignID.flatMap { campaignOptionsByID[$0] }
                )
            }
        return CreateGameCatalog(
            catalogRevision: document.catalogRevision,
            campaigns: campaigns,
            standaloneScenarios: campaignScenarios + sideStories
        )
    }

    private static func campaignOption(
        from campaign: CampaignCatalogCampaign,
        resolver: LocaleCatalogResolver?,
        displayRules: CreateGameDisplayRules
    ) -> CreateGameCampaignOption {
        CreateGameCampaignOption(
            id: campaign.id,
            title: resolveTitle(campaign.nameKey, resolver: resolver),
            nameKey: campaign.nameKey,
            alpha: campaign.alpha,
            beta: campaign.beta,
            dev: campaign.dev,
            returnTo: campaign.returnTo.flatMap { returnTo in
                guard displayRules.shouldDisplay(
                    alpha: returnTo.alpha, beta: returnTo.beta, dev: returnTo.dev
                ) else { return nil }
                return CreateGameReturnToCampaignOption(
                    id: returnTo.id,
                    title: Self.resolveTitle(returnTo.nameKey, resolver: resolver),
                    nameKey: returnTo.nameKey,
                    alpha: returnTo.alpha,
                    beta: returnTo.beta,
                    dev: returnTo.dev
                )
            },
            variants: campaign.variants.map { variant in
                let key = "create.fullCampaignOption.\(variant.key)"
                return CreateGameVariantOption(
                    id: variant.key,
                    label: Self.resolveTitle(key, resolver: resolver)
                )
            },
            recommendedOptions: recommendedOptions(
                from: campaign.recommendedOptions,
                resolver: resolver
            ),
            chapter: campaign.chapter
        )
    }

    private static func scenarioOption(
        from scenario: CampaignCatalogScenario,
        resolver: LocaleCatalogResolver?,
        isSideStory: Bool,
        parentCampaign: CreateGameCampaignOption?
    ) -> CreateGameScenarioOption {
        CreateGameScenarioOption(
            id: scenario.id,
            title: resolveTitle(scenario.nameKey, resolver: resolver),
            nameKey: scenario.nameKey,
            campaignID: isSideStory ? nil : scenario.campaignID,
            alpha: scenario.alpha,
            beta: scenario.beta,
            dev: scenario.dev,
            returnTo: zipOptionals(scenario.returnToID, scenario.returnToNameKey).map { id, nameKey in // swiftlint:disable:this line_length
                CreateGameReturnToScenarioOption(
                    id: id,
                    title: Self.resolveTitle(nameKey, resolver: resolver),
                    nameKey: nameKey
                )
            },
            returnToVariant: scenario.returnToVariant,
            difficulties: scenario.standaloneDifficulties ?? (isSideStory ? [] : RequestDifficulty.allCases), // swiftlint:disable:this line_length
            requiredInvestigator: scenario.requiredInvestigator,
            requiredInvestigatorCodes: scenario.requiredInvestigatorCodes,
            deckRequirements: scenario.deckRequirements,
            recommendedOptions: isSideStory ? [] : parentCampaign?.recommendedOptions ?? [],
            strictAsIfAtDefault: isSideStory ? false : parentCampaign?.strictAsIfAtDefault ?? false,
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

    private static func recommendedOptions(
        from options: [CampaignCatalogRecommendedOption],
        resolver: LocaleCatalogResolver?
    ) -> [CreateGameRecommendedOption] {
        options.map { option in
            let key = "create.recommendedOption.\(option.tag).title"
            return CreateGameRecommendedOption(
                id: option.tag,
                label: Self.resolveTitle(key, resolver: resolver),
                defaultEnabled: option.defaultEnabled,
                flag: CampaignOptionFlag(rawValue: option.tag)
            )
        }
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
