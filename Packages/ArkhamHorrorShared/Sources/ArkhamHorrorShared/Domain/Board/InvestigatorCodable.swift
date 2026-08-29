/// `Investigator`'s `Codable` conformance, kept in its own file purely to stay under
/// SwiftLint's file/function-length limits (see `Investigator.swift` for the type itself).
extension Investigator: Codable {
    private enum CodingKeys: String, CodingKey {
        case actionsPerformed
        case actionsTaken
        case additionalActions
        case agility
        case art
        case assets
        case assignedHealthDamage
        case assignedHealthHeal
        case assignedSanityDamage
        case assignedSanityHeal
        case beganRoundAt
        case bondedCards
        case cardCode
        case cardsUnderneath
        case investigatorClass = "class"
        case combat
        case connectedLocations
        case deck
        case deckBuildingAdjustments
        case deckSize
        case deckURL = "deckUrl"
        case decks
        case defeated
        case discard
        case discarding
        case discover
        case drawing
        case drawnCards
        case drivenInsane
        case eliminated
        case endedTurn
        case engagedEnemies
        case events
        case excludeFromMulligan
        case form
        case formMeta
        case hand
        case handSize
        case health
        case horrorHealed
        case id
        case intellect
        case keys
        case killed
        case log
        case mentalTrauma
        case meta
        case modifiers
        case movement
        case mulligansTaken
        case mutated
        case name
        case physicalTrauma
        case placement
        case playerID = "playerId"
        case previousLocation
        case remainingActions
        case resigned
        case sanity
        case scarletKeys
        case sealedChaosTokens
        case seals
        case search
        case settings
        case sideDeck
        case skills
        case skippedWindow
        case slots
        case spentXp
        case startsWith
        case startsWithInHand
        case supplies
        case taboo
        case tokens
        case traits
        case treacheries
        case unhealedHorrorThisRound
        case usedAbilities
        case usedAdditionalActions
        case willpower
        case experiencePoints = "xp"
    }

    // swiftlint:disable:next function_body_length
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = decoder.codingPath
        actionsPerformed = try container.decode([JSONValue].self, forKey: .actionsPerformed)
        actionsTaken = try container.decode([JSONValue].self, forKey: .actionsTaken)
        additionalActions = try container.decode([JSONValue].self, forKey: .additionalActions)
        agility = try container.decode(Int.self, forKey: .agility)
        art = try container.decode(String.self, forKey: .art)
        assets = try container.decode([AssetID].self, forKey: .assets)
        assignedHealthDamage = try container.decode(Int.self, forKey: .assignedHealthDamage)
        assignedHealthHeal = try container.decode([JSONValue].self, forKey: .assignedHealthHeal)
        assignedSanityDamage = try container.decode(Int.self, forKey: .assignedSanityDamage)
        assignedSanityHeal = try container.decode([JSONValue].self, forKey: .assignedSanityHeal)
        beganRoundAt = try decodeRequiredNullable(
            LocationID.self, from: container, forKey: .beganRoundAt,
            codingPath: path + [CodingKeys.beganRoundAt]
        )
        bondedCards = try container.decode([JSONValue].self, forKey: .bondedCards)
        cardCode = try container.decode(CardCode.self, forKey: .cardCode)
        cardsUnderneath = try container.decode([JSONValue].self, forKey: .cardsUnderneath)
        investigatorClass = try container.decode(ClassSymbol.self, forKey: .investigatorClass)
        combat = try container.decode(Int.self, forKey: .combat)
        connectedLocations = try container.decode([LocationID].self, forKey: .connectedLocations)
        deck = try container.decode([JSONValue].self, forKey: .deck)
        deckBuildingAdjustments = try container.decode(
            [JSONValue].self, forKey: .deckBuildingAdjustments
        )
        deckSize = try container.decode(Int.self, forKey: .deckSize)
        deckURL = try decodeRequiredNullable(
            String.self, from: container, forKey: .deckURL,
            codingPath: path + [CodingKeys.deckURL]
        )
        decks = try container.decode([JSONValue].self, forKey: .decks)
        defeated = try container.decode(Bool.self, forKey: .defeated)
        discard = try container.decode([JSONValue].self, forKey: .discard)
        discarding = try decodeRequiredNullable(
            JSONValue.self, from: container, forKey: .discarding,
            codingPath: path + [CodingKeys.discarding]
        )
        discover = try decodeRequiredNullable(
            JSONValue.self, from: container, forKey: .discover,
            codingPath: path + [CodingKeys.discover]
        )
        drawing = try decodeRequiredNullable(
            JSONValue.self, from: container, forKey: .drawing,
            codingPath: path + [CodingKeys.drawing]
        )
        drawnCards = try container.decode([JSONValue].self, forKey: .drawnCards)
        drivenInsane = try container.decode(Bool.self, forKey: .drivenInsane)
        eliminated = try container.decode(Bool.self, forKey: .eliminated)
        endedTurn = try container.decode(Bool.self, forKey: .endedTurn)
        engagedEnemies = try container.decode([EnemyID].self, forKey: .engagedEnemies)
        events = try container.decode([EventID].self, forKey: .events)
        excludeFromMulligan = try container.decode([JSONValue].self, forKey: .excludeFromMulligan)
        form = try container.decode(JSONValue.self, forKey: .form)
        formMeta = try container.decode(JSONValue.self, forKey: .formMeta)
        hand = try container.decode([JSONValue].self, forKey: .hand)
        handSize = try container.decode(Int.self, forKey: .handSize)
        health = try container.decode(Int.self, forKey: .health)
        horrorHealed = try container.decode(Int.self, forKey: .horrorHealed)
        id = try container.decode(InvestigatorID.self, forKey: .id)
        intellect = try container.decode(Int.self, forKey: .intellect)
        keys = try container.decode([JSONValue].self, forKey: .keys)
        killed = try container.decode(Bool.self, forKey: .killed)
        log = try container.decode(JSONValue.self, forKey: .log)
        mentalTrauma = try container.decode(Int.self, forKey: .mentalTrauma)
        meta = try container.decode(JSONValue.self, forKey: .meta)
        modifiers = try container.decode([JSONValue].self, forKey: .modifiers)
        movement = try decodeRequiredNullable(
            Movement.self, from: container, forKey: .movement,
            codingPath: path + [CodingKeys.movement]
        )
        mulligansTaken = try container.decode(Int.self, forKey: .mulligansTaken)
        mutated = try container.decode(JSONValue.self, forKey: .mutated)
        name = try container.decode(CardName.self, forKey: .name)
        physicalTrauma = try container.decode(Int.self, forKey: .physicalTrauma)
        placement = try container.decode(Placement.self, forKey: .placement)
        playerID = try container.decode(PlayerID.self, forKey: .playerID)
        previousLocation = try decodeRequiredNullable(
            LocationID.self, from: container, forKey: .previousLocation,
            codingPath: path + [CodingKeys.previousLocation]
        )
        remainingActions = try container.decode(Int.self, forKey: .remainingActions)
        resigned = try container.decode(Bool.self, forKey: .resigned)
        sanity = try container.decode(Int.self, forKey: .sanity)
        scarletKeys = try container.decode([CardCode].self, forKey: .scarletKeys)
        sealedChaosTokens = try container.decode([ChaosToken].self, forKey: .sealedChaosTokens)
        seals = try container.decode([JSONValue].self, forKey: .seals)
        search = try decodeRequiredNullable(
            JSONValue.self, from: container, forKey: .search,
            codingPath: path + [CodingKeys.search]
        )
        settings = try container.decode(JSONValue.self, forKey: .settings)
        sideDeck = try container.decode(JSONValue.self, forKey: .sideDeck)
        skills = try container.decode([SkillID].self, forKey: .skills)
        skippedWindow = try container.decode(Bool.self, forKey: .skippedWindow)
        slots = try container.decode([JSONValue].self, forKey: .slots)
        spentXp = try container.decode(Int.self, forKey: .spentXp)
        startsWith = try container.decode([JSONValue].self, forKey: .startsWith)
        startsWithInHand = try container.decode([JSONValue].self, forKey: .startsWithInHand)
        supplies = try container.decode([JSONValue].self, forKey: .supplies)
        taboo = try container.decode(JSONValue.self, forKey: .taboo)
        tokens = try container.decode([TokenCount].self, forKey: .tokens)
        traits = try container.decode([String].self, forKey: .traits)
        treacheries = try container.decode([TreacheryID].self, forKey: .treacheries)
        unhealedHorrorThisRound = try container.decode(
            Int.self, forKey: .unhealedHorrorThisRound
        )
        usedAbilities = try container.decode([JSONValue].self, forKey: .usedAbilities)
        usedAdditionalActions = try container.decode(
            [JSONValue].self, forKey: .usedAdditionalActions
        )
        willpower = try container.decode(Int.self, forKey: .willpower)
        experiencePoints = try container.decode(Int.self, forKey: .experiencePoints)
    }

    // swiftlint:disable:next function_body_length
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actionsPerformed, forKey: .actionsPerformed)
        try container.encode(actionsTaken, forKey: .actionsTaken)
        try container.encode(additionalActions, forKey: .additionalActions)
        try container.encode(agility, forKey: .agility)
        try container.encode(art, forKey: .art)
        try container.encode(assets, forKey: .assets)
        try container.encode(assignedHealthDamage, forKey: .assignedHealthDamage)
        try container.encode(assignedHealthHeal, forKey: .assignedHealthHeal)
        try container.encode(assignedSanityDamage, forKey: .assignedSanityDamage)
        try container.encode(assignedSanityHeal, forKey: .assignedSanityHeal)
        try container.encode(beganRoundAt, forKey: .beganRoundAt)
        try container.encode(bondedCards, forKey: .bondedCards)
        try container.encode(cardCode, forKey: .cardCode)
        try container.encode(cardsUnderneath, forKey: .cardsUnderneath)
        try container.encode(investigatorClass, forKey: .investigatorClass)
        try container.encode(combat, forKey: .combat)
        try container.encode(connectedLocations, forKey: .connectedLocations)
        try container.encode(deck, forKey: .deck)
        try container.encode(deckBuildingAdjustments, forKey: .deckBuildingAdjustments)
        try container.encode(deckSize, forKey: .deckSize)
        try container.encode(deckURL, forKey: .deckURL)
        try container.encode(decks, forKey: .decks)
        try container.encode(defeated, forKey: .defeated)
        try container.encode(discard, forKey: .discard)
        try container.encode(discarding, forKey: .discarding)
        try container.encode(discover, forKey: .discover)
        try container.encode(drawing, forKey: .drawing)
        try container.encode(drawnCards, forKey: .drawnCards)
        try container.encode(drivenInsane, forKey: .drivenInsane)
        try container.encode(eliminated, forKey: .eliminated)
        try container.encode(endedTurn, forKey: .endedTurn)
        try container.encode(engagedEnemies, forKey: .engagedEnemies)
        try container.encode(events, forKey: .events)
        try container.encode(excludeFromMulligan, forKey: .excludeFromMulligan)
        try container.encode(form, forKey: .form)
        try container.encode(formMeta, forKey: .formMeta)
        try container.encode(hand, forKey: .hand)
        try container.encode(handSize, forKey: .handSize)
        try container.encode(health, forKey: .health)
        try container.encode(horrorHealed, forKey: .horrorHealed)
        try container.encode(id, forKey: .id)
        try container.encode(intellect, forKey: .intellect)
        try container.encode(keys, forKey: .keys)
        try container.encode(killed, forKey: .killed)
        try container.encode(log, forKey: .log)
        try container.encode(mentalTrauma, forKey: .mentalTrauma)
        try container.encode(meta, forKey: .meta)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(movement, forKey: .movement)
        try container.encode(mulligansTaken, forKey: .mulligansTaken)
        try container.encode(mutated, forKey: .mutated)
        try container.encode(name, forKey: .name)
        try container.encode(physicalTrauma, forKey: .physicalTrauma)
        try container.encode(placement, forKey: .placement)
        try container.encode(playerID, forKey: .playerID)
        try container.encode(previousLocation, forKey: .previousLocation)
        try container.encode(remainingActions, forKey: .remainingActions)
        try container.encode(resigned, forKey: .resigned)
        try container.encode(sanity, forKey: .sanity)
        try container.encode(scarletKeys, forKey: .scarletKeys)
        try container.encode(sealedChaosTokens, forKey: .sealedChaosTokens)
        try container.encode(seals, forKey: .seals)
        try container.encode(search, forKey: .search)
        try container.encode(settings, forKey: .settings)
        try container.encode(sideDeck, forKey: .sideDeck)
        try container.encode(skills, forKey: .skills)
        try container.encode(skippedWindow, forKey: .skippedWindow)
        try container.encode(slots, forKey: .slots)
        try container.encode(spentXp, forKey: .spentXp)
        try container.encode(startsWith, forKey: .startsWith)
        try container.encode(startsWithInHand, forKey: .startsWithInHand)
        try container.encode(supplies, forKey: .supplies)
        try container.encode(taboo, forKey: .taboo)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(traits, forKey: .traits)
        try container.encode(treacheries, forKey: .treacheries)
        try container.encode(unhealedHorrorThisRound, forKey: .unhealedHorrorThisRound)
        try container.encode(usedAbilities, forKey: .usedAbilities)
        try container.encode(usedAdditionalActions, forKey: .usedAdditionalActions)
        try container.encode(willpower, forKey: .willpower)
        try container.encode(experiencePoints, forKey: .experiencePoints)
    }
}
