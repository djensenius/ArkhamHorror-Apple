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
    /// The server-published `canUpgradeDecks` flag from the current
    /// `ContinueCampaignStep`. This gates the upgrade-step answer even when the native UI
    /// hides the button for web-parity conditions such as the prologue.
    let canUpgradeDecks: Bool
    let chooseSideStory: Bool
    let canChooseSideStory: Bool
    /// Web-compatible button visibility: a real campaign, a scenario-type continuation,
    /// a completed scenario step, and the server's upgrade flag are all required.
    let canUpgrade: Bool

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
