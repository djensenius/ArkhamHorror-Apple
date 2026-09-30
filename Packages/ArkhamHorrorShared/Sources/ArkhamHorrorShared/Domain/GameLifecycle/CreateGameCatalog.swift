import Foundation

/// Option-driven native create-game catalog entries. Wire identifiers stay here, behind
/// display names, so the creation UI never asks a player to type or read raw server IDs.
struct CreateGameCatalog: Sendable, Equatable {
    let campaigns: [CreateGameCampaignOption]
    let standaloneScenarios: [CreateGameScenarioOption]

    static let nightOfTheZealotCampaign = CreateGameCampaignOption(
        id: "01", title: "The Night of the Zealot"
    )

    static let nightOfTheZealotScenarios: [CreateGameScenarioOption] = [
        CreateGameScenarioOption(
            id: "01104", title: "The Gathering", campaignID: nightOfTheZealotCampaign.id
        ),
        CreateGameScenarioOption(
            id: "01120", title: "The Midnight Masks", campaignID: nightOfTheZealotCampaign.id
        ),
        CreateGameScenarioOption(
            id: "01142", title: "The Devourer Below", campaignID: nightOfTheZealotCampaign.id
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
}

struct CreateGameScenarioOption: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let title: String
    let campaignID: String
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
            "Campaign"
        case .standaloneScenario:
            "Standalone scenario"
        }
    }
}

extension RequestDifficulty {
    var displayName: String {
        switch self {
        case .easy:
            "Easy"
        case .standard:
            "Standard"
        case .hard:
            "Hard"
        case .expert:
            "Expert"
        }
    }
}

extension RequestMultiplayerVariant {
    var displayName: String {
        switch self {
        case .solo:
            "Solo"
        case .withFriends:
            "With Friends"
        }
    }
}
