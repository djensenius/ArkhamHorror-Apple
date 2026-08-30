@testable import ArkhamHorrorShared
import Foundation

/// Investigator/act/agenda/snapshot builders for ``BoardTestFixtures``, split into this
/// extension purely to stay under SwiftLint's type-body-length budget for the primary
/// declaration.
extension BoardTestFixtures {
    static func investigator(
        id: InvestigatorID,
        name: CardName = CardName(title: "Test Investigator", subtitle: nil),
        investigatorClass: ClassSymbol = .guardian,
        health: Int = 9,
        sanity: Int = 5,
        remainingActions: Int = 3,
        physicalTrauma: Int = 0,
        mentalTrauma: Int = 0,
        unhealedHorrorThisRound: Int = 0,
        defeated: Bool = false,
        resigned: Bool = false,
        eliminated: Bool = false,
        drivenInsane: Bool = false,
        killed: Bool = false,
        engagedEnemies: [EnemyID] = [],
        assets: [AssetID] = [],
        events: [EventID] = [],
        treacheries: [TreacheryID] = [],
        skills: [SkillID] = [],
        scarletKeys: [CardCode] = [],
        tokens: [TokenCount] = [],
        movement: Movement? = nil,
        placement: Placement = BoardTestFixtures.placement()
    ) -> Investigator {
        Investigator(
            actionsPerformed: [], actionsTaken: [], additionalActions: [], agility: 3,
            art: id.rawValue.rawValue, assets: assets, assignedHealthDamage: 0,
            assignedHealthHeal: [], assignedSanityDamage: 0, assignedSanityHeal: [],
            beganRoundAt: nil, bondedCards: [], cardCode: id.rawValue, cardsUnderneath: [],
            investigatorClass: investigatorClass, combat: 3, connectedLocations: [], deck: [],
            deckBuildingAdjustments: [], deckSize: 0, deckURL: nil, decks: [], defeated: defeated,
            discard: [], discarding: nil, discover: nil, drawing: nil, drawnCards: [],
            drivenInsane: drivenInsane, eliminated: eliminated, endedTurn: false,
            engagedEnemies: engagedEnemies, events: events, excludeFromMulligan: [], form: .null,
            formMeta: .null, hand: [], handSize: 0, health: health, horrorHealed: 0, id: id,
            intellect: 3, keys: [], killed: killed, log: .null, mentalTrauma: mentalTrauma,
            meta: .null, modifiers: [], movement: movement, mulligansTaken: 0, mutated: .null,
            name: name, physicalTrauma: physicalTrauma, placement: placement,
            playerID: BoardTestFixtures.playerID(), previousLocation: nil,
            remainingActions: remainingActions, resigned: resigned, sanity: sanity,
            scarletKeys: scarletKeys, sealedChaosTokens: [], seals: [], search: nil,
            settings: .null, sideDeck: .null, skills: skills, skippedWindow: false, slots: [],
            spentXp: 0, startsWith: [], startsWithInHand: [], supplies: [], taboo: .null,
            tokens: tokens, traits: [], treacheries: treacheries,
            unhealedHorrorThisRound: unhealedHorrorThisRound, usedAbilities: [],
            usedAdditionalActions: [], willpower: 3, experiencePoints: 0
        )
    }

    static func act(
        id: ActID, deckID: Int = 1, sequence: ActSequence = ActSequence(step: 1, side: .sideA),
        flipped: Bool = false, advanceCost: RuntimeCost? = nil, tokens: [TokenCount] = [],
        treacheries: [TreacheryID] = []
    ) -> Act {
        Act(
            id: id, cardID: Identifier(UUID()), sequence: sequence, deckID: deckID,
            flipped: flipped, advanceCost: advanceCost, breaches: .null, cardsUnderneath: [],
            keys: [], meta: .null, modifiers: [], tokens: tokens, treacheries: treacheries,
            usedWheelOfFortuneX: false
        )
    }

    static func agenda(
        id: AgendaID, deckID: Int = 1,
        sequence: AgendaSequence = AgendaSequence(side: .sideA, step: 1), doom: Int = 0,
        doomThreshold: GameValue? = .staticValue(3), flipped: Bool = false,
        tokens: [TokenCount] = [], treacheries: [TreacheryID] = []
    ) -> Agenda {
        Agenda(
            id: id, cardID: Identifier(UUID()), sequence: sequence, deckID: deckID, doom: doom,
            doomThreshold: doomThreshold, flipped: flipped, cardsUnderneath: [], meta: .null,
            modifiers: [], removeDoomMatchers: .null, tokens: tokens, treacheries: treacheries,
            usedWheelOfFortuneX: false
        )
    }

    static func entityMap<Tag: Sendable>(count: Int) -> UUIDEntityMap<Tag> {
        var map = UUIDKeyedMap<Tag, JSONValue>()
        for _ in 0 ..< count {
            map[Identifier(UUID())] = .null
        }
        return map
    }

    static func snapshot(
        name: String = "Test game",
        mode: GameMode = .scenarioOnly(BoardTestFixtures.scenario()),
        locations: [(LocationID, Location)] = [],
        investigators: [InvestigatorID: Investigator] = [:],
        acts: [ActID: Act] = [:],
        agendas: [AgendaID: Agenda] = [:],
        playerOrder: [InvestigatorID] = [],
        activeInvestigatorID: InvestigatorID = investigatorID("c01001"),
        turnPlayerInvestigatorID: InvestigatorID? = nil,
        leadInvestigatorID: InvestigatorID = investigatorID("c01001"),
        phase: GamePhase = .investigation,
        phaseStep: PhaseStep? = .investigation(.investigatorTakesAction),
        gameState: GameState = .active,
        totalDoom: Int = 0,
        totalClues: Int = 0,
        enemyCount: Int = 0,
        assetCount: Int = 0,
        treacheryCount: Int = 0,
        eventCount: Int = 0,
        skillCount: Int = 0,
        concealedCount: Int = 0,
        cardCount: Int = 0,
        questionCount: Int = 0
    ) -> PublicGameSnapshot {
        var locationMap = UUIDKeyedMap<LocationIDTag, Location>()
        for (id, location) in locations {
            locationMap[id] = location
        }

        // Resolves to an investigator actually present in `investigators` whenever the
        // caller's (possibly just-defaulted) activeInvestigatorID/leadInvestigatorID does
        // not already name one — so a caller that supplies `investigators` without also
        // overriding these can never accidentally build an internally-inconsistent
        // snapshot the real contract fixtures would never emit. Falls back to the
        // caller-supplied value verbatim only when `investigators` is empty (there is
        // nothing to resolve to), preserving every existing explicit-override call site's
        // exact behavior.
        let sortedInvestigatorIDs = investigators.keys
            .sorted { $0.rawValue.rawValue < $1.rawValue.rawValue }
        let resolvedActiveInvestigatorID = investigators[activeInvestigatorID] != nil
            ? activeInvestigatorID
            : (sortedInvestigatorIDs.first ?? activeInvestigatorID)
        let resolvedLeadInvestigatorID = investigators[leadInvestigatorID] != nil
            ? leadInvestigatorID
            : (sortedInvestigatorIDs.first ?? leadInvestigatorID)

        return PublicGameSnapshot(
            name: name, id: BoardTestFixtures.gameID(), log: [], git: "test",
            settings: gameSettings(), gameSettings: gameSettings(), mode: mode, modifiers: [],
            encounterDeckSize: 0, locations: locationMap, investigators: investigators,
            otherInvestigators: [:], killedInvestigators: [:],
            enemies: entityMap(count: enemyCount), assets: entityMap(count: assetCount),
            acts: acts, agendas: agendas, treacheries: entityMap(count: treacheryCount),
            events: entityMap(count: eventCount), concealed: entityMap(count: concealedCount),
            skills: entityMap(count: skillCount), stories: [:], scarletKeys: [:],
            playerCount: max(investigators.count, 1),
            activeInvestigatorID: resolvedActiveInvestigatorID,
            activePlayerID: BoardTestFixtures.playerID(),
            turnPlayerInvestigatorID: turnPlayerInvestigatorID,
            leadInvestigatorID: resolvedLeadInvestigatorID, playerOrder: playerOrder, phase: phase,
            phaseStep: phaseStep, inAction: false, skillTest: nil, skillTestChaosTokens: [],
            focusedCards: [], highlightedCards: [], focusedTarotCards: [], foundCards: .null,
            focusedChaosTokens: [], activeCard: nil, removedFromPlay: [], gameState: gameState,
            inSetup: false, skillTestResults: nil,
            question: basicChoiceQuestions(count: questionCount),
            cards: entityMap(count: cardCount), totalDoom: totalDoom, totalClues: totalClues,
            scenarioSteps: 0, undoActionStep: nil, undoTurnStep: nil, undoPhaseStep: nil,
            undoRoundStep: nil, roundHistory: [:], phaseHistory: [:], turnHistory: [:],
            enemyAttackTargets: []
        )
    }

    private static func basicChoiceQuestions(
        count: Int
    ) -> UUIDKeyedMap<PlayerIDTag, BasicChoiceQuestionPayload> {
        var map = UUIDKeyedMap<PlayerIDTag, BasicChoiceQuestionPayload>()
        for _ in 0 ..< count {
            let raw: JSONValue = .object([
                "tag": .string("FutureQuestion"),
                "choices": .array([]),
            ])
            map[PlayerID(UUID())] = BasicChoiceQuestionPayload(
                rawValue: raw, state: .updateRequired(tag: "FutureQuestion")
            )
        }
        return map
    }
}
