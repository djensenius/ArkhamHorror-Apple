/// `PublicGameSnapshot`'s `Codable` conformance, kept in its own file purely to stay under
/// SwiftLint's file/function-length limits (see `PublicGameSnapshot.swift` for the type
/// itself).
extension PublicGameSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case name
        case id
        case log
        case git
        case settings
        case gameSettings
        case mode
        case modifiers
        case encounterDeckSize
        case locations
        case investigators
        case otherInvestigators
        case killedInvestigators
        case enemies
        case assets
        case acts
        case agendas
        case treacheries
        case events
        case concealed
        case skills
        case stories
        case scarletKeys
        case playerCount
        case activeInvestigatorID = "activeInvestigatorId"
        case activePlayerID = "activePlayerId"
        case turnPlayerInvestigatorID = "turnPlayerInvestigatorId"
        case leadInvestigatorID = "leadInvestigatorId"
        case playerOrder
        case phase
        case phaseStep
        case inAction
        case skillTest
        case skillTestChaosTokens
        case focusedCards
        case highlightedCards
        case focusedTarotCards
        case foundCards
        case focusedChaosTokens
        case activeCard
        case removedFromPlay
        case gameState
        case inSetup
        case skillTestResults
        case question
        case cards
        case totalDoom
        case totalClues
        case scenarioSteps
        case undoActionStep
        case undoTurnStep
        case undoPhaseStep
        case undoRoundStep
        case roundHistory
        case phaseHistory
        case turnHistory
        case enemyAttackTargets
    }

    // swiftlint:disable:next function_body_length
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = decoder.codingPath
        let tag = try container.decode(String.self, forKey: .tag)
        guard tag == "PublicGame" else {
            throw PublicGameSnapshotError.unexpectedTag(tag)
        }
        name = try container.decode(String.self, forKey: .name)
        id = try container.decode(GameID.self, forKey: .id)
        log = try container.decode([String].self, forKey: .log)
        git = try container.decode(String.self, forKey: .git)
        settings = try container.decode(GameSettings.self, forKey: .settings)
        gameSettings = try container.decode(GameSettings.self, forKey: .gameSettings)
        mode = try container.decode(GameMode.self, forKey: .mode)
        modifiers = try container.decode([JSONValue].self, forKey: .modifiers)
        encounterDeckSize = try container.decode(Int.self, forKey: .encounterDeckSize)
        locations = try container.decode([LocationID: Location].self, forKey: .locations)
        investigators = try container.decode(
            [InvestigatorID: Investigator].self, forKey: .investigators
        )
        otherInvestigators = try container.decode(
            [InvestigatorID: Investigator].self, forKey: .otherInvestigators
        )
        killedInvestigators = try container.decode(
            [InvestigatorID: Investigator].self, forKey: .killedInvestigators
        )
        enemies = try container.decode(UUIDEntityMap<EnemyIDTag>.self, forKey: .enemies)
        assets = try container.decode(UUIDEntityMap<AssetIDTag>.self, forKey: .assets)
        acts = try container.decode([ActID: Act].self, forKey: .acts)
        agendas = try container.decode([AgendaID: Agenda].self, forKey: .agendas)
        treacheries = try container.decode(
            UUIDEntityMap<TreacheryIDTag>.self, forKey: .treacheries
        )
        events = try container.decode(UUIDEntityMap<EventIDTag>.self, forKey: .events)
        concealed = try container.decode(UUIDEntityMap<ConcealedCardIDTag>.self, forKey: .concealed)
        skills = try container.decode(UUIDEntityMap<SkillIDTag>.self, forKey: .skills)
        stories = try container.decode(CardCodeEntityMap.self, forKey: .stories)
        scarletKeys = try container.decode(CardCodeEntityMap.self, forKey: .scarletKeys)
        playerCount = try container.decode(Int.self, forKey: .playerCount)
        activeInvestigatorID = try container.decode(
            InvestigatorID.self, forKey: .activeInvestigatorID
        )
        activePlayerID = try container.decode(PlayerID.self, forKey: .activePlayerID)
        turnPlayerInvestigatorID = try decodeRequiredNullable(
            InvestigatorID.self, from: container, forKey: .turnPlayerInvestigatorID,
            codingPath: path
        )
        leadInvestigatorID = try container.decode(
            InvestigatorID.self, forKey: .leadInvestigatorID
        )
        playerOrder = try container.decode([InvestigatorID].self, forKey: .playerOrder)
        phase = try container.decode(GamePhase.self, forKey: .phase)
        phaseStep = try NullablePhaseStep.decode(
            from: container.superDecoder(forKey: .phaseStep)
        )
        inAction = try container.decode(Bool.self, forKey: .inAction)
        skillTest = try decodeRequiredNullable(
            JSONValue.self, from: container, forKey: .skillTest, codingPath: path
        )
        skillTestChaosTokens = try container.decode(
            [JSONValue].self, forKey: .skillTestChaosTokens
        )
        focusedCards = try container.decode([JSONValue].self, forKey: .focusedCards)
        highlightedCards = try container.decode([String].self, forKey: .highlightedCards)
        focusedTarotCards = try container.decode([JSONValue].self, forKey: .focusedTarotCards)
        foundCards = try container.decode(JSONValue.self, forKey: .foundCards)
        focusedChaosTokens = try container.decode([JSONValue].self, forKey: .focusedChaosTokens)
        activeCard = try decodeRequiredNullable(
            JSONValue.self, from: container, forKey: .activeCard, codingPath: path
        )
        removedFromPlay = try container.decode([JSONValue].self, forKey: .removedFromPlay)
        gameState = try container.decode(GameState.self, forKey: .gameState)
        inSetup = try container.decode(Bool.self, forKey: .inSetup)
        skillTestResults = try decodeRequiredNullable(
            JSONValue.self, from: container, forKey: .skillTestResults, codingPath: path
        )
        question = try container.decode(UUIDEntityMap<PlayerIDTag>.self, forKey: .question)
        cards = try container.decode(UUIDEntityMap<WireCardIDTag>.self, forKey: .cards)
        totalDoom = try container.decode(Int.self, forKey: .totalDoom)
        totalClues = try container.decode(Int.self, forKey: .totalClues)
        scenarioSteps = try container.decode(Int.self, forKey: .scenarioSteps)
        undoActionStep = try decodeRequiredNullable(
            Int.self, from: container, forKey: .undoActionStep, codingPath: path
        )
        undoTurnStep = try decodeRequiredNullable(
            Int.self, from: container, forKey: .undoTurnStep, codingPath: path
        )
        undoPhaseStep = try decodeRequiredNullable(
            Int.self, from: container, forKey: .undoPhaseStep, codingPath: path
        )
        undoRoundStep = try decodeRequiredNullable(
            Int.self, from: container, forKey: .undoRoundStep, codingPath: path
        )
        roundHistory = try container.decode(CardCodeEntityMap.self, forKey: .roundHistory)
        phaseHistory = try container.decode(CardCodeEntityMap.self, forKey: .phaseHistory)
        turnHistory = try container.decode(CardCodeEntityMap.self, forKey: .turnHistory)
        enemyAttackTargets = try container.decode(
            [EnemyAttackTarget].self, forKey: .enemyAttackTargets
        )
    }

    // swiftlint:disable:next function_body_length
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("PublicGame", forKey: .tag)
        try container.encode(name, forKey: .name)
        try container.encode(id, forKey: .id)
        try container.encode(log, forKey: .log)
        try container.encode(git, forKey: .git)
        try container.encode(settings, forKey: .settings)
        try container.encode(gameSettings, forKey: .gameSettings)
        try container.encode(mode, forKey: .mode)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(encounterDeckSize, forKey: .encounterDeckSize)
        try container.encode(locations, forKey: .locations)
        try container.encode(investigators, forKey: .investigators)
        try container.encode(otherInvestigators, forKey: .otherInvestigators)
        try container.encode(killedInvestigators, forKey: .killedInvestigators)
        try container.encode(enemies, forKey: .enemies)
        try container.encode(assets, forKey: .assets)
        try container.encode(acts, forKey: .acts)
        try container.encode(agendas, forKey: .agendas)
        try container.encode(treacheries, forKey: .treacheries)
        try container.encode(events, forKey: .events)
        try container.encode(concealed, forKey: .concealed)
        try container.encode(skills, forKey: .skills)
        try container.encode(stories, forKey: .stories)
        try container.encode(scarletKeys, forKey: .scarletKeys)
        try container.encode(playerCount, forKey: .playerCount)
        try container.encode(activeInvestigatorID, forKey: .activeInvestigatorID)
        try container.encode(activePlayerID, forKey: .activePlayerID)
        try container.encode(turnPlayerInvestigatorID, forKey: .turnPlayerInvestigatorID)
        try container.encode(leadInvestigatorID, forKey: .leadInvestigatorID)
        try container.encode(playerOrder, forKey: .playerOrder)
        try container.encode(phase, forKey: .phase)
        try NullablePhaseStep.encode(phaseStep, to: container.superEncoder(forKey: .phaseStep))
        try container.encode(inAction, forKey: .inAction)
        try container.encode(skillTest, forKey: .skillTest)
        try container.encode(skillTestChaosTokens, forKey: .skillTestChaosTokens)
        try container.encode(focusedCards, forKey: .focusedCards)
        try container.encode(highlightedCards, forKey: .highlightedCards)
        try container.encode(focusedTarotCards, forKey: .focusedTarotCards)
        try container.encode(foundCards, forKey: .foundCards)
        try container.encode(focusedChaosTokens, forKey: .focusedChaosTokens)
        try container.encode(activeCard, forKey: .activeCard)
        try container.encode(removedFromPlay, forKey: .removedFromPlay)
        try container.encode(gameState, forKey: .gameState)
        try container.encode(inSetup, forKey: .inSetup)
        try container.encode(skillTestResults, forKey: .skillTestResults)
        try container.encode(question, forKey: .question)
        try container.encode(cards, forKey: .cards)
        try container.encode(totalDoom, forKey: .totalDoom)
        try container.encode(totalClues, forKey: .totalClues)
        try container.encode(scenarioSteps, forKey: .scenarioSteps)
        try container.encode(undoActionStep, forKey: .undoActionStep)
        try container.encode(undoTurnStep, forKey: .undoTurnStep)
        try container.encode(undoPhaseStep, forKey: .undoPhaseStep)
        try container.encode(undoRoundStep, forKey: .undoRoundStep)
        try container.encode(roundHistory, forKey: .roundHistory)
        try container.encode(phaseHistory, forKey: .phaseHistory)
        try container.encode(turnHistory, forKey: .turnHistory)
        try container.encode(enemyAttackTargets, forKey: .enemyAttackTargets)
    }
}
