/// Phantom tag distinguishing ``GamePhase``.
enum GamePhaseTag: Sendable {}
/// `PublicGame.phase` (`Arkham.Phase.Phase`).
typealias GamePhase = OpenStringEnum<GamePhaseTag>

extension GamePhase {
    static let mythos = GamePhase("MythosPhase")
    static let investigation = GamePhase("InvestigationPhase")
    static let enemy = GamePhase("EnemyPhase")
    static let upkeep = GamePhase("UpkeepPhase")
    static let resolution = GamePhase("ResolutionPhase")
    static let campaign = GamePhase("CampaignPhase")
}

/// One entry of `PublicGame.enemyAttackTargets`.
struct EnemyAttackTarget: Sendable {
    let enemy: String
    /// `Arkham.Target.Target`. Broad tagged union, out of scope for this contract slice.
    let target: JSONValue
}

extension EnemyAttackTarget: Equatable, Hashable, Codable {}

/// Thrown when decoding a `PublicGame` value whose `tag` is not the literal `"PublicGame"`
/// this shape's encoder always emits.
enum PublicGameSnapshotError: Error, Equatable, Sendable {
    case unexpectedTag(String)
}

/// The top-level authoritative game snapshot published over REST (`GetGame.game`) and
/// WebSocket (`GameUpdate.contents`) (`Arkham.Types.Game.PublicGame`, backend PR #45).
/// Pinned byte-for-byte to backend commit `ee6efffa4d7a49f2ac7bf6b9349802d3d7675ae5`,
/// schema revision `0.1.21`. Read-only: this type is never submitted back to the server.
struct PublicGameSnapshot: Sendable {
    let name: String
    let id: GameID
    let log: [String]
    let git: String
    let settings: GameSettings
    let gameSettings: GameSettings
    let mode: GameMode
    /// `PublicGame.modifiers`. Broad and additive, out of scope for this contract slice.
    let modifiers: [JSONValue]
    let encounterDeckSize: Int
    let locations: UUIDKeyedMap<LocationIDTag, Location>
    let investigators: [InvestigatorID: Investigator]
    let otherInvestigators: [InvestigatorID: Investigator]
    let killedInvestigators: [InvestigatorID: Investigator]
    let enemies: UUIDEntityMap<EnemyIDTag>
    let assets: UUIDEntityMap<AssetIDTag>
    let acts: [ActID: Act]
    let agendas: [AgendaID: Agenda]
    let treacheries: UUIDEntityMap<TreacheryIDTag>
    let events: UUIDEntityMap<EventIDTag>
    let concealed: UUIDEntityMap<ConcealedCardIDTag>
    let skills: UUIDEntityMap<SkillIDTag>
    let stories: CardCodeEntityMap
    let scarletKeys: CardCodeEntityMap
    let playerCount: Int
    let activeInvestigatorID: InvestigatorID
    let activePlayerID: PlayerID
    let turnPlayerInvestigatorID: InvestigatorID?
    let leadInvestigatorID: InvestigatorID
    let playerOrder: [InvestigatorID]
    let phase: GamePhase
    let phaseStep: PhaseStep?
    let inAction: Bool
    /// `PublicGame.skillTest`. Broad, out of scope for this contract slice.
    let skillTest: JSONValue?
    let skillTestChaosTokens: [JSONValue]
    let focusedCards: [JSONValue]
    let highlightedCards: [String]
    let focusedTarotCards: [JSONValue]
    /// `PublicGame.foundCards`. Broad, out of scope for this contract slice.
    let foundCards: JSONValue
    let focusedChaosTokens: [JSONValue]
    /// `PublicGame.activeCard`. Broad, out of scope for this contract slice.
    let activeCard: JSONValue?
    let removedFromPlay: [JSONValue]
    let gameState: GameState
    let inSetup: Bool
    /// `PublicGame.skillTestResults`. Broad, out of scope for this contract slice.
    let skillTestResults: JSONValue?
    /// Exact player-keyed question payloads. Each value retains its full raw JSON while
    /// recognizing only the narrow basic-choice slice this client can safely answer.
    let question: UUIDKeyedMap<PlayerIDTag, BasicChoiceQuestionPayload>
    let cards: UUIDEntityMap<WireCardIDTag>
    let totalDoom: Int
    let totalClues: Int
    let scenarioSteps: Int
    let undoActionStep: Int?
    let undoTurnStep: Int?
    let undoPhaseStep: Int?
    let undoRoundStep: Int?
    let roundHistory: CardCodeEntityMap
    let phaseHistory: CardCodeEntityMap
    let turnHistory: CardCodeEntityMap
    let enemyAttackTargets: [EnemyAttackTarget]
}

extension PublicGameSnapshot: Equatable, Hashable {}
