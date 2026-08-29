@testable import ArkhamHorrorShared
import Foundation

/// Shared test-only builders for ``PublicGameSnapshot`` and its constituent entity types.
///
/// Every builder supplies safe, minimal defaults for every field this contract slice
/// leaves broad/out-of-scope (`JSONValue`/`[JSONValue]` fields, in particular), and
/// exposes only the handful of fields that matter to ``BoardProjectionBuilder`` as
/// overridable parameters — so a projection edge-case test can construct a realistic,
/// fully-valid snapshot without restating every one of its ~50 fields inline. These
/// builders call each production type's own compiler-synthesized memberwise
/// initializer directly (every `Codable` conformance in this contract slice lives in a
/// separate `extension`, never inside the primary type declaration, so the memberwise
/// initializer is never suppressed) — this exercises the exact same production types
/// ``BoardProjectionBuilder`` consumes, just without a JSON decode round-trip, which the
/// dedicated fixture-decode tests already cover byte-for-byte.
enum BoardTestFixtures {
    static func cardCode(_ raw: String) -> CardCode {
        // swiftlint:disable:next force_try
        try! CardCode(raw)
    }

    static func investigatorID(_ raw: String) -> InvestigatorID {
        InvestigatorID(cardCode(raw))
    }

    static func actID(_ raw: String) -> ActID {
        ActID(cardCode(raw))
    }

    static func agendaID(_ raw: String) -> AgendaID {
        AgendaID(cardCode(raw))
    }

    static func locationID(_ uuidSuffix: String) -> LocationID {
        // swiftlint:disable:next force_unwrapping
        LocationID(UUID(uuidString: "00000000-0000-0000-0000-\(uuidSuffix)")!)
    }

    static func gameID(_ uuidSuffix: String = "000000000900") -> GameID {
        // swiftlint:disable:next force_unwrapping
        GameID(UUID(uuidString: "00000000-0000-0000-0000-\(uuidSuffix)")!)
    }

    static func playerID(_ uuidSuffix: String = "000000000800") -> PlayerID {
        // swiftlint:disable:next force_unwrapping
        PlayerID(UUID(uuidString: "00000000-0000-0000-0000-\(uuidSuffix)")!)
    }

    static func gameSettings() -> GameSettings {
        GameSettings(
            abilitiesCannotReactToThemselves: false,
            achievementsEnabled: false,
            asIfRuling: .chapter1,
            rolledUltimatumOrBoon: nil,
            screamedAllies: [],
            strictAsIfAt: false,
            ultimatumsAndBoons: [],
            ultimatumsAndBoonsEnabled: false
        )
    }

    static func placement(_ kind: PlacementKind = .atLocation) -> Placement {
        Placement(kind: kind, contents: .absent)
    }

    static func chaosBag(
        chaosTokens: [ChaosToken] = [], revealedChaosTokens: [ChaosToken] = [],
        setAsideChaosTokens: [ChaosToken] = [], forceDraw: ChaosTokenFace? = nil,
        choice: JSONValue? = nil
    ) -> ChaosBag {
        ChaosBag(
            chaosTokens: chaosTokens, setAsideChaosTokens: setAsideChaosTokens,
            revealedChaosTokens: revealedChaosTokens, choice: choice, forceDraw: forceDraw,
            tokenPool: [], totalRevealedChaosTokens: [], pendingRequests: []
        )
    }

    static func chaosToken(_ face: ChaosTokenFace, sealed: Bool = false) -> ChaosToken {
        ChaosToken(
            chaosTokenID: Identifier(UUID()), chaosTokenFace: face, chaosTokenRevealedBy: nil,
            chaosTokenCancelled: false, chaosTokenSealed: sealed
        )
    }

    static func scenario(
        id: CardCode = cardCode("c01104"),
        name: CardName = CardName(title: "Test Scenario", subtitle: nil),
        difficulty: Difficulty = .easy,
        turn: Int = 1,
        chaosBag: ChaosBag = BoardTestFixtures.chaosBag(),
        usesGrid: Bool = false,
        isPrelude: Bool = false,
        isSideStory: Bool = false,
        inResolution: Bool = false,
        started: Bool = true
    ) -> Scenario {
        Scenario(
            actStack: .null, activeEncounterDeck: "", additionalReferences: [], agendaStack: .null,
            campaignStep: .null, cardsNextToActDeck: [], cardsNextToAgendaDeck: [],
            cardsUnderActDeck: [], cardsUnderAgendaDeck: [], cardsUnderScenarioReference: [],
            chaosBag: chaosBag, completedActStack: [], completedAgendaStack: [], counts: [],
            deckDiscards: [], decks: [], decksLayout: [], defeatedEnemies: .null,
            difficulty: difficulty, discard: [], encounterDeck: [], encounterDecks: [],
            grid: ScenarioGrid(gridAbove: [], gridBelow: [], gridCenter: []),
            hasEncounterDeck: false, id: id, inResolution: inResolution, inShuffle: false,
            isPrelude: isPrelude, isSideStory: isSideStory, keys: [], locationLayout: [], log: [],
            meta: .null, name: name, noRemainingInvestigatorsHandler: .null, options: .null,
            playerDecks: .null, reference: "reference", resignedCardCodes: [],
            resolvedStories: [], scope: "scope", search: .null, setAsideCards: [],
            setAsideKeys: [],
            standaloneCampaignLog: ScenarioCampaignLog(
                crossedOut: [], options: [], orderedKeys: [], partners: .null, recorded: [],
                recordedCounts: [], recordedSets: []
            ),
            started: started, storyCards: .null, tarotCards: [], tarotDeck: [], timesPlayed: 0,
            tokens: [], turn: turn, useHardExpertReference: false, usesGrid: usesGrid,
            victoryDisplay: [], xpBreakdown: .null
        )
    }

    static func ordinaryLocation(
        id: LocationID,
        cardCode: CardCode = cardCode("c01111"),
        label: String = "Location",
        revealed: Bool = true,
        symbol: LocationSymbol = .circle,
        revealedSymbol: LocationSymbol = .circle,
        shroud: GameValue? = .staticValue(2),
        investigateSkill: Skill = .intellect,
        tokens: [TokenCount] = [],
        connectedLocations: [LocationID] = [],
        investigators: [InvestigatorID] = [],
        enemies: [EnemyID] = [],
        assets: [AssetID] = [],
        events: [EventID] = [],
        treacheries: [TreacheryID] = [],
        concealedCards: [JSONValue] = [],
        placement: Placement? = nil,
        costToEnterUnrevealed: RuntimeCost = RuntimeCost(tag: "Free", contents: nil)
    ) -> OrdinaryLocation {
        OrdinaryLocation(
            id: id, cardCode: cardCode, cardID: Identifier(UUID()), label: label,
            revealClues: .staticValue(1), tokens: tokens, shroud: shroud, revealed: revealed,
            symbol: symbol, revealedSymbol: revealedSymbol, connectedMatchers: [],
            revealedConnectedMatchers: [], directions: [], connectsTo: [], cardsUnderneath: [],
            costToEnterUnrevealed: costToEnterUnrevealed, canBeFlipped: false,
            investigateSkill: investigateSkill, placement: placement, keys: [], seals: [],
            sealedChaosTokens: [], placedChaosTokens: [], floodLevel: .null, brazier: .null,
            breaches: .null, withoutClues: false, meta: .null, globalMeta: .null, position: .null,
            beingRemoved: false, concealedCards: concealedCards, outOfGame: false,
            connectedLocations: connectedLocations, investigators: investigators, enemies: enemies,
            assets: assets, events: events, treacheries: treacheries, scarletKeys: [], modifiers: []
        )
    }

    static func enemyLocation(
        id: LocationID,
        cardCode: CardCode = cardCode("c10547"),
        label: String = "Enemy location",
        revealed: Bool = true,
        exhausted: Bool = false,
        shroud: GameValue? = nil,
        tokens: [TokenCount] = [],
        investigators: [InvestigatorID] = [],
        enemies: [EnemyID] = [],
        connectedLocations: [LocationID] = []
    ) -> EnemyLocationView {
        EnemyLocationView(
            id: id, cardID: Identifier(UUID()), cardCode: cardCode, label: label, tokens: tokens,
            shroud: shroud, revealed: revealed, exhausted: exhausted, investigators: investigators,
            enemies: enemies, treacheries: [], assets: [], events: [], scarletKeys: [],
            cardsUnderneath: [], modifiers: [], connectedLocations: connectedLocations,
            placement: nil, brazier: .null, breaches: .null, floodLevel: .null, keys: [],
            seals: [], sealedChaosTokens: [], concealedCards: []
        )
    }

    static func movement(
        means: MovementMeans = .direct, destination: MovementDestination
    ) -> Movement {
        Movement(
            moveSource: .null, moveTarget: .null, moveDestination: destination, moveMeans: means,
            moveCancelable: true, movePayAdditionalCosts: false, moveAfter: [],
            moveAdditionalEnterCosts: RuntimeCost(tag: "Free", contents: nil),
            moveSkipEngagement: false, moveID: Identifier(UUID()), moveForced: false,
            moveFromInPlay: false
        )
    }
}
