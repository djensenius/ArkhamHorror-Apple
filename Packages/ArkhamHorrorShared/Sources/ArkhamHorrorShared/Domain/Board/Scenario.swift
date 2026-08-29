/// `Scenario.grid`: the optional grid-based board layout. Broad, out of scope for this
/// contract slice.
struct ScenarioGrid: Sendable {
    let gridAbove: [JSONValue]
    let gridBelow: [JSONValue]
    let gridCenter: [JSONValue]
}

extension ScenarioGrid: Equatable, Hashable, Codable {}

/// `Scenario.standaloneCampaignLog`: the (empty, for a fresh standalone scenario) campaign
/// log a scenario reads and writes. Broad, out of scope for this contract slice.
struct ScenarioCampaignLog: Sendable {
    let crossedOut: [JSONValue]
    let options: [JSONValue]
    let orderedKeys: [JSONValue]
    let partners: JSONValue
    let recorded: [JSONValue]
    let recordedCounts: [JSONValue]
    let recordedSets: [JSONValue]
}

extension ScenarioCampaignLog: Equatable, Hashable, Codable {}

/// The `That` (scenario) branch of `PublicGame.mode`
/// (`Arkham.Scenario.Types.ScenarioAttrs`). Broad card-union/matcher/metadata payloads
/// remain intentionally out of scope for this contract slice; only the stable top-level
/// field set, ids, and scalar stats are asserted exactly.
struct Scenario: Sendable {
    /// The act deck, grouped by `[deckIndex, [cards]]`. Broad card union, out of scope.
    let actStack: JSONValue
    let activeEncounterDeck: String
    let additionalReferences: [JSONValue]
    /// The agenda deck, grouped by `[deckIndex, [cards]]`. Broad card union, out of scope.
    let agendaStack: JSONValue
    /// The active `CampaignStep`, when this scenario is running as part of a campaign.
    /// Broad, out of scope for this contract slice.
    let campaignStep: JSONValue
    let cardsNextToActDeck: [JSONValue]
    let cardsNextToAgendaDeck: [JSONValue]
    let cardsUnderActDeck: [JSONValue]
    let cardsUnderAgendaDeck: [JSONValue]
    let cardsUnderScenarioReference: [JSONValue]
    let chaosBag: ChaosBag
    let completedActStack: [JSONValue]
    let completedAgendaStack: [JSONValue]
    /// Free-form scenario counters. Broad, out of scope for this contract slice.
    let counts: [JSONValue]
    let deckDiscards: [JSONValue]
    let decks: [JSONValue]
    /// The act/agenda deck row layout, for example `["agenda1 act1"]`.
    let decksLayout: [String]
    /// Defeated-enemy bookkeeping, keyed by card code. Broad, out of scope.
    let defeatedEnemies: JSONValue
    let difficulty: Difficulty
    /// The encounter discard pile. Broad card union, out of scope.
    let discard: [JSONValue]
    /// The encounter deck. Broad card union, out of scope.
    let encounterDeck: [JSONValue]
    let encounterDecks: [JSONValue]
    let grid: ScenarioGrid
    let hasEncounterDeck: Bool
    let id: CardCode
    let inResolution: Bool
    let inShuffle: Bool
    let isPrelude: Bool
    let isSideStory: Bool
    let keys: [JSONValue]
    /// The scenario's fixed grid-topology reference art, one string per row.
    let locationLayout: [String]
    let log: [String]
    /// Free-form scenario metadata.
    let meta: JSONValue
    let name: CardName
    /// The `Target` to notify when no investigators remain. Broad tagged union beyond
    /// its tag, out of scope for this contract slice.
    let noRemainingInvestigatorsHandler: JSONValue
    /// Scenario-specific options selected at creation. Broad, out of scope.
    let options: JSONValue
    /// Per-player deck bookkeeping, keyed by player id. Broad, out of scope.
    let playerDecks: JSONValue
    let reference: String
    let resignedCardCodes: [String]
    let resolvedStories: [JSONValue]
    let scope: String
    /// In-progress card-search state, if any. Broad, out of scope.
    let search: JSONValue
    /// Cards set aside during setup, not yet placed or drawn. Broad card union, out of
    /// scope.
    let setAsideCards: [JSONValue]
    let setAsideKeys: [JSONValue]
    let standaloneCampaignLog: ScenarioCampaignLog
    let started: Bool
    let storyCards: JSONValue
    let tarotCards: [JSONValue]
    let tarotDeck: [JSONValue]
    let timesPlayed: Int
    /// Tokens placed directly on the scenario reference card. Broad, out of scope.
    let tokens: [JSONValue]
    /// `ScenarioAttrs.scenarioTurn`. Initializes at 0 before the scenario's first turn
    /// begins.
    let turn: Int
    let useHardExpertReference: Bool
    let usesGrid: Bool
    let victoryDisplay: [JSONValue]
    /// Experience-point breakdown shown at scenario resolution. Broad, out of scope.
    let xpBreakdown: JSONValue
}

extension Scenario: Equatable, Hashable {}

extension Scenario: Codable {
    private enum CodingKeys: String, CodingKey {
        case actStack
        case activeEncounterDeck
        case additionalReferences
        case agendaStack
        case campaignStep
        case cardsNextToActDeck
        case cardsNextToAgendaDeck
        case cardsUnderActDeck
        case cardsUnderAgendaDeck
        case cardsUnderScenarioReference
        case chaosBag
        case completedActStack
        case completedAgendaStack
        case counts
        case deckDiscards
        case decks
        case decksLayout
        case defeatedEnemies
        case difficulty
        case discard
        case encounterDeck
        case encounterDecks
        case grid
        case hasEncounterDeck
        case id
        case inResolution
        case inShuffle
        case isPrelude
        case isSideStory
        case keys
        case locationLayout
        case log
        case meta
        case name
        case noRemainingInvestigatorsHandler
        case options
        case playerDecks
        case reference
        case resignedCardCodes
        case resolvedStories
        case scope
        case search
        case setAsideCards
        case setAsideKeys
        case standaloneCampaignLog
        case started
        case storyCards
        case tarotCards
        case tarotDeck
        case timesPlayed
        case tokens
        case turn
        case useHardExpertReference
        case usesGrid
        case victoryDisplay
        case xpBreakdown
    }

    // swiftlint:disable:next function_body_length
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actStack = try container.decode(JSONValue.self, forKey: .actStack)
        activeEncounterDeck = try container.decode(String.self, forKey: .activeEncounterDeck)
        additionalReferences = try container.decode(
            [JSONValue].self, forKey: .additionalReferences
        )
        agendaStack = try container.decode(JSONValue.self, forKey: .agendaStack)
        campaignStep = try container.decode(JSONValue.self, forKey: .campaignStep)
        cardsNextToActDeck = try container.decode([JSONValue].self, forKey: .cardsNextToActDeck)
        cardsNextToAgendaDeck = try container.decode(
            [JSONValue].self, forKey: .cardsNextToAgendaDeck
        )
        cardsUnderActDeck = try container.decode([JSONValue].self, forKey: .cardsUnderActDeck)
        cardsUnderAgendaDeck = try container.decode(
            [JSONValue].self, forKey: .cardsUnderAgendaDeck
        )
        cardsUnderScenarioReference = try container.decode(
            [JSONValue].self, forKey: .cardsUnderScenarioReference
        )
        chaosBag = try container.decode(ChaosBag.self, forKey: .chaosBag)
        completedActStack = try container.decode([JSONValue].self, forKey: .completedActStack)
        completedAgendaStack = try container.decode(
            [JSONValue].self, forKey: .completedAgendaStack
        )
        counts = try container.decode([JSONValue].self, forKey: .counts)
        deckDiscards = try container.decode([JSONValue].self, forKey: .deckDiscards)
        decks = try container.decode([JSONValue].self, forKey: .decks)
        decksLayout = try container.decode([String].self, forKey: .decksLayout)
        defeatedEnemies = try container.decode(JSONValue.self, forKey: .defeatedEnemies)
        difficulty = try container.decode(Difficulty.self, forKey: .difficulty)
        discard = try container.decode([JSONValue].self, forKey: .discard)
        encounterDeck = try container.decode([JSONValue].self, forKey: .encounterDeck)
        encounterDecks = try container.decode([JSONValue].self, forKey: .encounterDecks)
        grid = try container.decode(ScenarioGrid.self, forKey: .grid)
        hasEncounterDeck = try container.decode(Bool.self, forKey: .hasEncounterDeck)
        id = try container.decode(CardCode.self, forKey: .id)
        inResolution = try container.decode(Bool.self, forKey: .inResolution)
        inShuffle = try container.decode(Bool.self, forKey: .inShuffle)
        isPrelude = try container.decode(Bool.self, forKey: .isPrelude)
        isSideStory = try container.decode(Bool.self, forKey: .isSideStory)
        keys = try container.decode([JSONValue].self, forKey: .keys)
        locationLayout = try container.decode([String].self, forKey: .locationLayout)
        log = try container.decode([String].self, forKey: .log)
        meta = try container.decode(JSONValue.self, forKey: .meta)
        name = try container.decode(CardName.self, forKey: .name)
        noRemainingInvestigatorsHandler = try container.decode(
            JSONValue.self, forKey: .noRemainingInvestigatorsHandler
        )
        options = try container.decode(JSONValue.self, forKey: .options)
        playerDecks = try container.decode(JSONValue.self, forKey: .playerDecks)
        reference = try container.decode(String.self, forKey: .reference)
        resignedCardCodes = try container.decode([String].self, forKey: .resignedCardCodes)
        resolvedStories = try container.decode([JSONValue].self, forKey: .resolvedStories)
        scope = try container.decode(String.self, forKey: .scope)
        search = try container.decode(JSONValue.self, forKey: .search)
        setAsideCards = try container.decode([JSONValue].self, forKey: .setAsideCards)
        setAsideKeys = try container.decode([JSONValue].self, forKey: .setAsideKeys)
        standaloneCampaignLog = try container.decode(
            ScenarioCampaignLog.self, forKey: .standaloneCampaignLog
        )
        started = try container.decode(Bool.self, forKey: .started)
        storyCards = try container.decode(JSONValue.self, forKey: .storyCards)
        tarotCards = try container.decode([JSONValue].self, forKey: .tarotCards)
        tarotDeck = try container.decode([JSONValue].self, forKey: .tarotDeck)
        timesPlayed = try container.decode(Int.self, forKey: .timesPlayed)
        tokens = try container.decode([JSONValue].self, forKey: .tokens)
        turn = try container.decode(Int.self, forKey: .turn)
        guard turn >= 0 else {
            let context = DecodingError.Context(
                codingPath: container.codingPath + [CodingKeys.turn],
                debugDescription: "Expected a non-negative scenario turn, got \(turn)"
            )
            throw DecodingError.dataCorrupted(context)
        }
        useHardExpertReference = try container.decode(Bool.self, forKey: .useHardExpertReference)
        usesGrid = try container.decode(Bool.self, forKey: .usesGrid)
        victoryDisplay = try container.decode([JSONValue].self, forKey: .victoryDisplay)
        xpBreakdown = try container.decode(JSONValue.self, forKey: .xpBreakdown)
    }

    // swiftlint:disable:next function_body_length
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actStack, forKey: .actStack)
        try container.encode(activeEncounterDeck, forKey: .activeEncounterDeck)
        try container.encode(additionalReferences, forKey: .additionalReferences)
        try container.encode(agendaStack, forKey: .agendaStack)
        try container.encode(campaignStep, forKey: .campaignStep)
        try container.encode(cardsNextToActDeck, forKey: .cardsNextToActDeck)
        try container.encode(cardsNextToAgendaDeck, forKey: .cardsNextToAgendaDeck)
        try container.encode(cardsUnderActDeck, forKey: .cardsUnderActDeck)
        try container.encode(cardsUnderAgendaDeck, forKey: .cardsUnderAgendaDeck)
        try container.encode(cardsUnderScenarioReference, forKey: .cardsUnderScenarioReference)
        try container.encode(chaosBag, forKey: .chaosBag)
        try container.encode(completedActStack, forKey: .completedActStack)
        try container.encode(completedAgendaStack, forKey: .completedAgendaStack)
        try container.encode(counts, forKey: .counts)
        try container.encode(deckDiscards, forKey: .deckDiscards)
        try container.encode(decks, forKey: .decks)
        try container.encode(decksLayout, forKey: .decksLayout)
        try container.encode(defeatedEnemies, forKey: .defeatedEnemies)
        try container.encode(difficulty, forKey: .difficulty)
        try container.encode(discard, forKey: .discard)
        try container.encode(encounterDeck, forKey: .encounterDeck)
        try container.encode(encounterDecks, forKey: .encounterDecks)
        try container.encode(grid, forKey: .grid)
        try container.encode(hasEncounterDeck, forKey: .hasEncounterDeck)
        try container.encode(id, forKey: .id)
        try container.encode(inResolution, forKey: .inResolution)
        try container.encode(inShuffle, forKey: .inShuffle)
        try container.encode(isPrelude, forKey: .isPrelude)
        try container.encode(isSideStory, forKey: .isSideStory)
        try container.encode(keys, forKey: .keys)
        try container.encode(locationLayout, forKey: .locationLayout)
        try container.encode(log, forKey: .log)
        try container.encode(meta, forKey: .meta)
        try container.encode(name, forKey: .name)
        try container.encode(
            noRemainingInvestigatorsHandler, forKey: .noRemainingInvestigatorsHandler
        )
        try container.encode(options, forKey: .options)
        try container.encode(playerDecks, forKey: .playerDecks)
        try container.encode(reference, forKey: .reference)
        try container.encode(resignedCardCodes, forKey: .resignedCardCodes)
        try container.encode(resolvedStories, forKey: .resolvedStories)
        try container.encode(scope, forKey: .scope)
        try container.encode(search, forKey: .search)
        try container.encode(setAsideCards, forKey: .setAsideCards)
        try container.encode(setAsideKeys, forKey: .setAsideKeys)
        try container.encode(standaloneCampaignLog, forKey: .standaloneCampaignLog)
        try container.encode(started, forKey: .started)
        try container.encode(storyCards, forKey: .storyCards)
        try container.encode(tarotCards, forKey: .tarotCards)
        try container.encode(tarotDeck, forKey: .tarotDeck)
        try container.encode(timesPlayed, forKey: .timesPlayed)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(turn, forKey: .turn)
        try container.encode(useHardExpertReference, forKey: .useHardExpertReference)
        try container.encode(usesGrid, forKey: .usesGrid)
        try container.encode(victoryDisplay, forKey: .victoryDisplay)
        try container.encode(xpBreakdown, forKey: .xpBreakdown)
    }
}

/// Thrown when decoding `PublicGame.mode`'s `These Campaign Scenario` shape finds neither
/// a `This` nor a `That` sibling key.
enum GameModeError: Error, Equatable, Sendable {
    case missingThisAndThat
}

/// `PublicGame.mode`: a `These Campaign Scenario` (the "these" package). `These a b` values
/// encode via sibling keys in a single JSON object (`This a` -> `{"This":a}`; `That b` ->
/// `{"That":b}`; `These a b` -> `{"This":a,"That":b}`), never a wrapping `"These"` key.
/// Fresh standalone play is always the `That`-only branch; `This`-only (between-scenario
/// campaign screens) and the `This`+`That` running-campaign-scenario branch are real,
/// reachable states, but the `Campaign` payload stays broad (a lossless ``JSONValue``)
/// pending a dedicated campaign contract slice.
enum GameMode: Sendable {
    /// `This`-only: a `Campaign` snapshot with no active scenario.
    case campaignOnly(JSONValue)
    /// `That`-only: a standalone scenario with no enclosing campaign.
    case scenarioOnly(Scenario)
    /// `This`+`That`: both an active `Campaign` and its currently running `Scenario`.
    case campaignAndScenario(campaign: JSONValue, scenario: Scenario)
}

extension GameMode: Equatable, Hashable {}

extension GameMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case this = "This"
        case that = "That"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasThis = container.contains(.this)
        let hasThat = container.contains(.that)
        switch (hasThis, hasThat) {
        case (true, true):
            self = try .campaignAndScenario(
                campaign: container.decode(JSONValue.self, forKey: .this),
                scenario: container.decode(Scenario.self, forKey: .that)
            )
        case (true, false):
            self = try .campaignOnly(container.decode(JSONValue.self, forKey: .this))
        case (false, true):
            self = try .scenarioOnly(container.decode(Scenario.self, forKey: .that))
        case (false, false):
            throw GameModeError.missingThisAndThat
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .campaignOnly(campaign):
            try container.encode(campaign, forKey: .this)
        case let .scenarioOnly(scenario):
            try container.encode(scenario, forKey: .that)
        case let .campaignAndScenario(campaign, scenario):
            try container.encode(campaign, forKey: .this)
            try container.encode(scenario, forKey: .that)
        }
    }
}
