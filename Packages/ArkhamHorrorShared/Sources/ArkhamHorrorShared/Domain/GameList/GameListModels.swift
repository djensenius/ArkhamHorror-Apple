/// Phantom tag distinguishing ``Difficulty``.
enum DifficultyTag: Sendable {}
/// A game's difficulty level. Shared between the game-lifecycle contract
/// (`CreateGameRequest.difficulty`) and the game-list contract (scenario/campaign summaries).
typealias Difficulty = OpenStringEnum<DifficultyTag>

extension Difficulty {
    static let easy = Difficulty("Easy")
    static let standard = Difficulty("Standard")
    static let hard = Difficulty("Hard")
    static let expert = Difficulty("Expert")
}

/// Phantom tag distinguishing ``MultiplayerVariant``.
enum MultiplayerVariantTag: Sendable {}
/// Whether a game is solo or played with friends. Shared between the game-lifecycle and
/// game-list contracts.
typealias MultiplayerVariant = OpenStringEnum<MultiplayerVariantTag>

extension MultiplayerVariant {
    static let solo = MultiplayerVariant("Solo")
    static let withFriends = MultiplayerVariant("WithFriends")
}

/// Phantom tag distinguishing ``CampaignMode``.
enum CampaignModeTag: Sendable {}
/// A campaign's current chapter mode, for example `TheDreamQuest`.
typealias CampaignMode = OpenStringEnum<CampaignModeTag>

extension CampaignMode {
    static let theDreamQuest = CampaignMode("TheDreamQuest")
    static let theWebOfDreams = CampaignMode("TheWebOfDreams")
}

/// `GameListEntry`'s scenario summary.
struct ScenarioSummary: Sendable, Equatable {
    let id: String
    let difficulty: Difficulty
    let name: CardName
    let variant: String?
}

extension ScenarioSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case difficulty
        case name
        case variant
    }

    /// `variant` is required by the schema but nullable: a missing key is a contract
    /// violation, while an explicit `null` means the scenario has no variant.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        difficulty = try container.decode(Difficulty.self, forKey: .difficulty)
        name = try container.decode(CardName.self, forKey: .name)
        variant = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .variant,
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(difficulty, forKey: .difficulty)
        try container.encode(name, forKey: .name)
        try container.encode(variant, forKey: .variant)
    }
}

/// `GameListEntry`'s campaign summary.
struct CampaignSummary: Sendable, Equatable {
    let id: String
    let difficulty: Difficulty
    let currentCampaignMode: CampaignMode?
}

extension CampaignSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case difficulty
        case currentCampaignMode
    }

    /// `currentCampaignMode` is required by the schema but nullable: a missing key is a
    /// contract violation, while an explicit `null` means no chapter mode has been set yet.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        difficulty = try container.decode(Difficulty.self, forKey: .difficulty)
        currentCampaignMode = try decodeRequiredNullable(
            CampaignMode.self,
            from: container,
            forKey: .currentCampaignMode,
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(difficulty, forKey: .difficulty)
        try container.encode(currentCampaignMode, forKey: .currentCampaignMode)
    }
}

/// One investigator entry within a `GameListEntry`'s `investigators`/`otherInvestigators`.
struct InvestigatorSummary: Sendable, Equatable, Codable {
    let id: String
    let classSymbol: ClassSymbol
}

/// A game entry that failed to load; `GameListEntry`'s alternative to ``GameSummary``.
struct FailedGameEntry: Sendable, Equatable, Codable {
    let error: String
}

/// A single successfully loaded game summary, as returned by `GET /arkham/games`.
struct GameSummary: Sendable, Equatable {
    let id: GameID
    let scenario: ScenarioSummary?
    let campaign: CampaignSummary?
    let gameState: GameState
    let name: String
    let investigators: [InvestigatorSummary]
    let otherInvestigators: [InvestigatorSummary]
    let multiplayerVariant: MultiplayerVariant
    let hasOpenSeats: Bool
}

extension GameSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case scenario
        case campaign
        case gameState
        case name
        case investigators
        case otherInvestigators
        case multiplayerVariant
        case hasOpenSeats
    }

    /// `scenario` and `campaign` are both required by the schema but nullable: a missing
    /// key is a contract violation, while an explicit `null` is the normal way a game
    /// outside a scenario/campaign context is represented.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(GameID.self, forKey: .id)
        scenario = try decodeRequiredNullable(
            ScenarioSummary.self,
            from: container,
            forKey: .scenario,
            codingPath: decoder.codingPath
        )
        campaign = try decodeRequiredNullable(
            CampaignSummary.self,
            from: container,
            forKey: .campaign,
            codingPath: decoder.codingPath
        )
        gameState = try container.decode(GameState.self, forKey: .gameState)
        name = try container.decode(String.self, forKey: .name)
        investigators = try container.decode([InvestigatorSummary].self, forKey: .investigators)
        otherInvestigators = try container.decode(
            [InvestigatorSummary].self,
            forKey: .otherInvestigators
        )
        multiplayerVariant = try container.decode(
            MultiplayerVariant.self,
            forKey: .multiplayerVariant
        )
        hasOpenSeats = try container.decode(Bool.self, forKey: .hasOpenSeats)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(scenario, forKey: .scenario)
        try container.encode(campaign, forKey: .campaign)
        try container.encode(gameState, forKey: .gameState)
        try container.encode(name, forKey: .name)
        try container.encode(investigators, forKey: .investigators)
        try container.encode(otherInvestigators, forKey: .otherInvestigators)
        try container.encode(multiplayerVariant, forKey: .multiplayerVariant)
        try container.encode(hasOpenSeats, forKey: .hasOpenSeats)
    }
}

/// One row of `GET /arkham/games`: either a successfully loaded game summary or a row that
/// failed to load.
enum GameListEntry: Sendable {
    case game(GameSummary)
    case failed(FailedGameEntry)
}

extension GameListEntry: Equatable {}

extension GameListEntry: Codable {
    /// Discriminates the two `GameListEntry` shapes by key presence rather than by
    /// speculatively decoding one shape and swallowing its errors: `error` is unique to
    /// ``FailedGameEntry``, `id` is unique to ``GameSummary``. This keeps genuine decode
    /// failures (contract drift) from being silently reinterpreted as the other shape.
    private enum DiscriminatorKeys: String, CodingKey {
        case id
        case error
    }

    init(from decoder: any Decoder) throws {
        let discriminator = try decoder.container(keyedBy: DiscriminatorKeys.self)
        if discriminator.contains(.error) {
            self = try .failed(FailedGameEntry(from: decoder))
        } else if discriminator.contains(.id) {
            self = try .game(GameSummary(from: decoder))
        } else {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a game-list row with an \"id\" or \"error\" key"
            )
            throw DecodingError.dataCorrupted(context)
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case let .game(summary):
            try summary.encode(to: encoder)
        case let .failed(entry):
            try entry.encode(to: encoder)
        }
    }
}

/// Games visible to the authenticated account, ordered by most recently updated, as
/// returned by `GET /arkham/games`.
typealias GameList = [GameListEntry]
