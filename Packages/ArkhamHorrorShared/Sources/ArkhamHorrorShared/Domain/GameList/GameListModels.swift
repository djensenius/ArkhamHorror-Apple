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
struct ScenarioSummary: Sendable, Equatable, Codable {
    let id: String
    let difficulty: Difficulty
    let name: CardName
    let variant: String?
}

/// `GameListEntry`'s campaign summary.
struct CampaignSummary: Sendable, Equatable, Codable {
    let id: String
    let difficulty: Difficulty
    let currentCampaignMode: CampaignMode?
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
struct GameSummary: Sendable, Equatable, Codable {
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

/// One row of `GET /arkham/games`: either a successfully loaded game summary or a row that
/// failed to load.
enum GameListEntry: Sendable {
    case game(GameSummary)
    case failed(FailedGameEntry)
}

extension GameListEntry: Equatable {}

extension GameListEntry: Codable {
    init(from decoder: any Decoder) throws {
        if let summary = try? GameSummary(from: decoder) {
            self = .game(summary)
            return
        }
        self = try .failed(FailedGameEntry(from: decoder))
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
