/// An enemy-spawned pseudo-location, produced by `Arkham.Game.withEnemyLocationAsLocationData`
/// for entries in `gameEntities.entitiesEnemyLocations` (`Arkham.Location.EnemyLocation`).
/// This is a materially smaller, disjoint field set from an ordinary `LocationAttrs`-backed
/// location: it always carries `enemyLocation: true` and `exhausted`, and omits
/// ordinary-only fields such as `symbol`/`revealedSymbol`/`directions`/`connectsTo`/`meta`/
/// `position` entirely (the encoder builds a fixed literal object, not `LocationAttrs`'s own
/// encoding).
struct EnemyLocationView: Sendable {
    let id: LocationID
    let cardID: WireCardID
    let cardCode: CardCode
    let label: String
    let tokens: [TokenCount]
    let shroud: GameValue?
    let revealed: Bool
    let exhausted: Bool
    let investigators: [InvestigatorID]
    let enemies: [EnemyID]
    let treacheries: [TreacheryID]
    let assets: [AssetID]
    let events: [EventID]
    let scarletKeys: [CardCode]
    let cardsUnderneath: [JSONValue]
    let modifiers: [JSONValue]
    let connectedLocations: [LocationID]
    let placement: Placement?
    let brazier: JSONValue
    let breaches: JSONValue
    let floodLevel: JSONValue
    let keys: [JSONValue]
    let seals: [JSONValue]
    let sealedChaosTokens: [ChaosToken]
    let concealedCards: [JSONValue]
}

extension EnemyLocationView: Equatable, Hashable {}

/// Thrown when decoding an ``EnemyLocationView`` whose `enemyLocation` key is present but
/// not the literal `true` this shape's encoder always emits.
enum EnemyLocationViewError: Error, Equatable, Sendable {
    case enemyLocationFlagNotTrue
}

extension EnemyLocationView: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case cardID = "cardId"
        case cardCode
        case label
        case tokens
        case shroud
        case revealed
        case enemyLocation
        case exhausted
        case investigators
        case enemies
        case treacheries
        case assets
        case events
        case scarletKeys
        case cardsUnderneath
        case modifiers
        case connectedLocations
        case placement
        case brazier
        case breaches
        case floodLevel
        case keys
        case seals
        case sealedChaosTokens
        case concealedCards
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enemyLocationFlag = try container.decode(Bool.self, forKey: .enemyLocation)
        guard enemyLocationFlag else {
            throw EnemyLocationViewError.enemyLocationFlagNotTrue
        }
        id = try container.decode(LocationID.self, forKey: .id)
        cardID = try container.decode(WireCardID.self, forKey: .cardID)
        cardCode = try container.decode(CardCode.self, forKey: .cardCode)
        label = try container.decode(String.self, forKey: .label)
        tokens = try container.decode([TokenCount].self, forKey: .tokens)
        shroud = try decodeRequiredNullable(
            GameValue.self,
            from: container,
            forKey: .shroud,
            codingPath: decoder.codingPath + [CodingKeys.shroud]
        )
        revealed = try container.decode(Bool.self, forKey: .revealed)
        exhausted = try container.decode(Bool.self, forKey: .exhausted)
        investigators = try container.decode([InvestigatorID].self, forKey: .investigators)
        enemies = try container.decode([EnemyID].self, forKey: .enemies)
        treacheries = try container.decode([TreacheryID].self, forKey: .treacheries)
        assets = try container.decode([AssetID].self, forKey: .assets)
        events = try container.decode([EventID].self, forKey: .events)
        scarletKeys = try container.decode([CardCode].self, forKey: .scarletKeys)
        cardsUnderneath = try container.decode([JSONValue].self, forKey: .cardsUnderneath)
        modifiers = try container.decode([JSONValue].self, forKey: .modifiers)
        connectedLocations = try container.decode([LocationID].self, forKey: .connectedLocations)
        placement = try decodeRequiredNullable(
            Placement.self,
            from: container,
            forKey: .placement,
            codingPath: decoder.codingPath + [CodingKeys.placement]
        )
        brazier = try container.decode(JSONValue.self, forKey: .brazier)
        breaches = try container.decode(JSONValue.self, forKey: .breaches)
        floodLevel = try container.decode(JSONValue.self, forKey: .floodLevel)
        keys = try container.decode([JSONValue].self, forKey: .keys)
        seals = try container.decode([JSONValue].self, forKey: .seals)
        sealedChaosTokens = try container.decode([ChaosToken].self, forKey: .sealedChaosTokens)
        concealedCards = try container.decode([JSONValue].self, forKey: .concealedCards)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(cardID, forKey: .cardID)
        try container.encode(cardCode, forKey: .cardCode)
        try container.encode(label, forKey: .label)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(shroud, forKey: .shroud)
        try container.encode(revealed, forKey: .revealed)
        try container.encode(true, forKey: .enemyLocation)
        try container.encode(exhausted, forKey: .exhausted)
        try container.encode(investigators, forKey: .investigators)
        try container.encode(enemies, forKey: .enemies)
        try container.encode(treacheries, forKey: .treacheries)
        try container.encode(assets, forKey: .assets)
        try container.encode(events, forKey: .events)
        try container.encode(scarletKeys, forKey: .scarletKeys)
        try container.encode(cardsUnderneath, forKey: .cardsUnderneath)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(connectedLocations, forKey: .connectedLocations)
        try container.encode(placement, forKey: .placement)
        try container.encode(brazier, forKey: .brazier)
        try container.encode(breaches, forKey: .breaches)
        try container.encode(floodLevel, forKey: .floodLevel)
        try container.encode(keys, forKey: .keys)
        try container.encode(seals, forKey: .seals)
        try container.encode(sealedChaosTokens, forKey: .sealedChaosTokens)
        try container.encode(concealedCards, forKey: .concealedCards)
    }
}

/// A location entity as published in `PublicGame.locations`. This map holds two
/// structurally disjoint shapes from two different production encoders (see
/// ``OrdinaryLocation``/``EnemyLocationView``), disambiguated here by the presence of the
/// literal `"enemyLocation": true` key that only the enemy-spawned pseudo-location shape
/// ever carries.
enum Location: Sendable {
    case ordinary(OrdinaryLocation)
    case enemy(EnemyLocationView)
}

extension Location: Equatable, Hashable {}

extension Location: Codable {
    private enum DiscriminatorKeys: String, CodingKey {
        case enemyLocation
    }

    init(from decoder: any Decoder) throws {
        let discriminator = try decoder.container(keyedBy: DiscriminatorKeys.self)
        if discriminator.contains(.enemyLocation) {
            self = try .enemy(EnemyLocationView(from: decoder))
        } else {
            self = try .ordinary(OrdinaryLocation(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case let .ordinary(location):
            try location.encode(to: encoder)
        case let .enemy(location):
            try location.encode(to: encoder)
        }
    }
}
