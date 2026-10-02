/// The server-owned continuation data for a campaign/scenario hand-off. ``nextStep`` is
/// copied verbatim from the authoritative snapshot and is the only payload the native
/// client submits for a plain `ContinueCampaign` answer.
struct CampaignContinuationContext: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case campaign
        case scenario
    }

    let source: Source
    let nextStep: JSONValue
    let canUpgradeDecks: Bool
    let chooseSideStory: Bool
    let canChooseSideStory: Bool

    var upgradeStep: JSONValue {
        .object([
            "tag": .string("UpgradeDeckStep"),
            "contents": .object([
                "tag": .string("ContinueCampaignStep"),
                "contents": .object([
                    "canUpgradeDecks": .bool(true),
                    "nextStep": nextStep,
                ]),
            ]),
        ])
    }
}
