import Foundation

/// A stable-keyed multiset entry for on-board token piles (for example clues or doom),
/// sorted by ``token`` using plain (non-locale-sensitive) `String` comparison so its order
/// never depends on the user's current locale or on `Dictionary` iteration order.
struct BoardTokenSummary: Sendable, Equatable {
    let token: String
    let count: Int
}

/// A chaos token face grouped with how many physical tokens currently carry it.
struct BoardChaosFaceCount: Sendable, Equatable {
    let face: ChaosTokenFace
    let count: Int
}

/// The scenario/reference summary (`PublicGame.mode`'s `That` branch), when an active
/// scenario exists. `nil` at the ``BoardProjection`` level explicitly represents "no active
/// scenario" (a `This`-only campaign screen) rather than an empty/blank board.
struct BoardScenarioSummary: Sendable, Equatable {
    let displayName: String
    let subtitle: String?
    let difficulty: Difficulty
    let turn: Int
    let reference: String
    let usesGrid: Bool
    let isPrelude: Bool
    let isSideStory: Bool
    let inResolution: Bool
    let started: Bool
}

/// One act entity, ordered deterministically by ``BoardProjectionBuilder``.
struct BoardActNode: Sendable, Equatable, Identifiable {
    let id: ActID
    let cardCode: CardCode
    let deckID: Int
    let sequence: ActSequence
    let flipped: Bool
    /// A safe, display-only summary of `Act.advanceCost`'s wire tag (for example
    /// "Group Clue Cost"), or `nil` when no advance cost was recorded. Never interprets
    /// the cost's actual rules effect.
    let advanceCostSummary: String?
    let tokenCounts: [BoardTokenSummary]
    let treacheryCount: Int
    let cardsUnderneathCount: Int
}

/// One agenda entity, ordered deterministically by ``BoardProjectionBuilder``.
struct BoardAgendaNode: Sendable, Equatable, Identifiable {
    let id: AgendaID
    let cardCode: CardCode
    let deckID: Int
    let sequence: AgendaSequence
    let doom: Int
    /// A safe, display-only summary of `Agenda.doomThreshold`, or `nil` when absent.
    let doomThresholdSummary: String?
    let flipped: Bool
    let tokenCounts: [BoardTokenSummary]
    let treacheryCount: Int
    let cardsUnderneathCount: Int
}

/// One ordinary (non-enemy-spawned) location, `Arkham.Location.Base.LocationAttrs`.
struct BoardLocationNode: Sendable, Equatable, Identifiable {
    let id: LocationID
    let cardCode: CardCode
    let displayLabel: String
    let revealed: Bool
    /// The printed connection symbol for whichever side (`revealedSymbol` if `revealed`,
    /// else `symbol`) currently faces up.
    let symbol: LocationSymbol
    let shroudSummary: String?
    let investigateSkill: Skill
    let clueCount: Int
    let doomCount: Int
    let otherTokenCounts: [BoardTokenSummary]
    let investigatorIDs: [InvestigatorID]
    let enemyCount: Int
    let assetCount: Int
    let eventCount: Int
    let treacheryCount: Int
    let concealedCount: Int
    /// Sorted (by raw UUID text) for deterministic topology, independent of the wire
    /// array's own order.
    let connectedLocationIDs: [LocationID]
    let placementSummary: String?
}

/// One enemy-spawned pseudo-location (`Arkham.Location.EnemyLocation`): a materially
/// smaller field set than ``BoardLocationNode``, with no symbol/shroud-based investigation
/// affordance.
struct BoardEnemyLocationNode: Sendable, Equatable, Identifiable {
    let id: LocationID
    let cardCode: CardCode
    let displayLabel: String
    let revealed: Bool
    let exhausted: Bool
    let shroudSummary: String?
    let tokenCounts: [BoardTokenSummary]
    let investigatorIDs: [InvestigatorID]
    let enemyCount: Int
    let assetCount: Int
    let eventCount: Int
    let treacheryCount: Int
    let concealedCount: Int
    let connectedLocationIDs: [LocationID]
}

/// One investigator entity (`PublicGame.investigators`), ordered by `PublicGame.playerOrder`.
struct BoardInvestigatorNode: Sendable, Equatable, Identifiable {
    let id: InvestigatorID
    let displayName: String
    let subtitle: String?
    let investigatorClass: ClassSymbol
    let health: Int
    let sanity: Int
    let remainingActions: Int
    let physicalTrauma: Int
    let mentalTrauma: Int
    /// Can be negative; see `Investigator.unhealedHorrorThisRound`'s own documentation.
    /// This projection never clamps it.
    let unhealedHorrorThisRound: Int
    let assignedHealthDamage: Int
    let assignedSanityDamage: Int
    let defeated: Bool
    let resigned: Bool
    let eliminated: Bool
    let drivenInsane: Bool
    /// Resolved by a single reverse-lookup pass over locations (see
    /// ``BoardProjectionBuilder``), never by re-scanning per investigator. `nil` when no
    /// location's `investigators` array names this investigator.
    let currentLocationID: LocationID?
    let isActiveInvestigator: Bool
    let isTurnPlayer: Bool
    let isLeadInvestigator: Bool
    let engagedEnemyCount: Int
    let assetCount: Int
    let eventCount: Int
    let treacheryCount: Int
    let skillCount: Int
    let scarletKeyCount: Int
    let tokenCounts: [BoardTokenSummary]
    /// A safe, display-only summary of an in-progress `Movement`, or `nil` when not
    /// currently moving.
    let movementSummary: String?
    let placementSummary: String
}

/// The scenario's chaos bag, summarized as face-grouped counts rather than a card-by-card
/// listing.
struct BoardChaosBagSummary: Sendable, Equatable {
    let poolCounts: [BoardChaosFaceCount]
    let revealedCounts: [BoardChaosFaceCount]
    let setAsideCounts: [BoardChaosFaceCount]
    let forceDrawFace: ChaosTokenFace?
    /// Whether an in-progress chaos-bag draw/resolution step exists. Deliberately not
    /// further detailed: `ChaosBag.choice`'s payload is broad and out of scope.
    let hasPendingChoice: Bool

    /// Whether every field here carries no information at all: no pool/revealed/set-
    /// aside tokens, no forced draw, and no pending choice. This is a legitimate,
    /// fully-decoded state (for example a fresh scenario whose bag has not yet been
    /// populated) — never "unsupported" — so callers must render/announce it as neutrally
    /// empty, not as deferred/unrecognized content. Used (instead of checking
    /// `poolCounts`/`revealedCounts` alone) so a chaos bag that only has set-aside tokens,
    /// a forced draw, or a pending choice is never misrepresented as empty.
    var isEntirelyEmpty: Bool {
        poolCounts.isEmpty && revealedCounts.isEmpty && setAsideCounts.isEmpty
            && forceDrawFace == nil && !hasPendingChoice
    }
}

/// Whether the board currently has an active scenario to show a chaos bag for at all.
/// `ChaosBag` itself always decodes fully typed (it has no `unknown`/deferred wire
/// shape), so the only two real states are "no active scenario" (a `This`-only campaign
/// screen) and "an active scenario's chaos bag" — which may itself be legitimately empty.
/// Collapsing these two into a single ``BoardChaosBagSummary`` (as an earlier revision of
/// this projection did) made a genuinely empty, fully-decoded bag indistinguishable from
/// having no scenario at all, so both rendered the same "not supported" notice — this
/// type exists specifically to keep that distinction explicit end to end.
enum BoardChaosBagState: Sendable, Equatable {
    case noActiveScenario
    case scenario(BoardChaosBagSummary)

    /// The three mutually-exclusive, fully-representable display states a chaos bag can
    /// ever be in — the single source of truth both ``BoardChaosBagView`` (on-screen) and
    /// ``BoardAccessibility/summary(chaosBag:)`` (VoiceOver) branch on, so a test can
    /// assert the same categorization both surfaces actually render/announce without
    /// instantiating either view.
    var displayState: BoardChaosBagDisplayState {
        switch self {
        case .noActiveScenario:
            .noActiveScenario
        case let .scenario(summary):
            summary.isEntirelyEmpty ? .empty : .populated(summary)
        }
    }
}

/// See ``BoardChaosBagState/displayState``.
enum BoardChaosBagDisplayState: Sendable, Equatable {
    case noActiveScenario
    case empty
    case populated(BoardChaosBagSummary)
}

/// Scenario-wide entity counts for the entity kinds this contract slice leaves as broad
/// key-only maps (`enemies`, `assets`, `treacheries`, `events`, `skills`, `concealed`,
/// `cards`): counts and stacks only, never inferred names or rules content.
struct BoardEntityCounters: Sendable, Equatable {
    let enemies: Int
    let assets: Int
    let treacheries: Int
    let events: Int
    let skills: Int
    let concealed: Int
    let cards: Int
}

/// Scenario-wide phase/turn/counter summary.
struct BoardCounters: Sendable, Equatable {
    let totalDoom: Int
    let totalClues: Int
    let encounterDeckSize: Int
    let scenarioSteps: Int
    let playerCount: Int
    let phase: GamePhase
    /// A safe, display-only summary of `PublicGame.phaseStep`, or `nil` while no step is
    /// active (for example during `CampaignPhase`/`ResolutionPhase`).
    let phaseStepSummary: String?
    let gameStateSummary: String
    let inSetup: Bool
    let inAction: Bool
    /// `PublicGame.question.count`: how many pending player prompts exist. Never further
    /// detailed (`question`'s value shape is broad and out of scope).
    let pendingPromptCount: Int
    let entityCounters: BoardEntityCounters
}

/// A typed, immutable, deterministic presentation projection built from a decoded
/// ``PublicGameSnapshot``. This is not a second rules engine: every field here is either
/// copied verbatim from the snapshot or is a purely cosmetic display-string derived from a
/// closed/known wire tag. No field infers legality, resolves a matcher, or interprets a
/// broad ``JSONValue`` payload's semantic meaning.
///
/// Two independently-decoded snapshots with equal field values always produce an equal
/// ``BoardProjection`` (see ``BoardProjectionBuilder``), which is what lets the REST and
/// WebSocket fixtures assert projection equality directly.
struct BoardProjection: Sendable, Equatable {
    let gameName: String
    /// Whether `PublicGame.mode` carries a `This` (campaign) package at all, regardless of
    /// whether `scenario` is also present. Used to render an explicit "campaign summary
    /// requires a future update" placeholder rather than silently omitting it.
    let hasCampaignContext: Bool
    let scenario: BoardScenarioSummary?
    /// Ordered by `(deckID, sequence.step, sequence.side, id)` for full determinism.
    let acts: [BoardActNode]
    /// Ordered by `(deckID, sequence.step, sequence.side, id)` for full determinism.
    let agendas: [BoardAgendaNode]
    /// Ordered by raw UUID text for full determinism, independent of any layout.
    let locations: [BoardLocationNode]
    let enemyLocations: [BoardEnemyLocationNode]
    /// Ordered by `PublicGame.playerOrder`, then any remaining investigators (not named in
    /// `playerOrder`) by raw card-code text.
    let investigators: [BoardInvestigatorNode]
    let otherInvestigatorCount: Int
    let killedInvestigatorCount: Int
    let chaosBag: BoardChaosBagState
    let counters: BoardCounters
}
