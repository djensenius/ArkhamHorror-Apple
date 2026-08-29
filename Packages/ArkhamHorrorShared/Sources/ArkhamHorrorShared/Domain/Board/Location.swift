/// Phantom tag distinguishing ``LocationSymbol``.
enum LocationSymbolTag: Sendable {}
/// A location's printed connection symbol (`Arkham.Location.Base`).
typealias LocationSymbol = OpenStringEnum<LocationSymbolTag>

extension LocationSymbol {
    static let circle = LocationSymbol("Circle")
    static let square = LocationSymbol("Square")
    static let triangle = LocationSymbol("Triangle")
    static let plus = LocationSymbol("Plus")
    static let diamond = LocationSymbol("Diamond")
    static let squiggle = LocationSymbol("Squiggle")
    static let moon = LocationSymbol("Moon")
    static let hourglass = LocationSymbol("Hourglass")
    static let tSymbol = LocationSymbol("T")
    static let equals = LocationSymbol("Equals")
    static let heart = LocationSymbol("Heart")
    static let star = LocationSymbol("Star")
    static let droplet = LocationSymbol("Droplet")
    static let trefoil = LocationSymbol("Trefoil")
    static let spade = LocationSymbol("Spade")
    static let noSymbol = LocationSymbol("NoSymbol")
}

/// Phantom tag distinguishing ``GridDirection``.
enum GridDirectionTag: Sendable {}
/// A grid Direction this location opens toward (`Location.connectsTo`). Empty outside
/// grid-based scenarios.
typealias GridDirection = OpenStringEnum<GridDirectionTag>

extension GridDirection {
    static let above = GridDirection("Above")
    static let below = GridDirection("Below")
    static let leftOf = GridDirection("LeftOf")
    static let rightOf = GridDirection("RightOf")
}

/// A location entity as published in `PublicGame.locations`
/// (`Arkham.Location.Base.LocationAttrs` plus the computed connection/occupant fields
/// `Arkham.Game.withLocationConnectionData` merges in). Matcher, cost, and card-union
/// payloads remain intentionally broad.
struct OrdinaryLocation: Sendable {
    let id: LocationID
    let cardCode: CardCode
    let cardID: WireCardID
    let label: String
    let revealClues: GameValue
    let tokens: [TokenCount]
    let shroud: GameValue?
    let revealed: Bool
    let symbol: LocationSymbol
    let revealedSymbol: LocationSymbol
    /// Unrevealed-side connection matchers (`Arkham.Matcher.Location.LocationMatcher`).
    /// Broad and out of scope for this contract slice.
    let connectedMatchers: [JSONValue]
    /// Revealed-side connection matchers (`Arkham.Matcher.Location.LocationMatcher`).
    /// Broad and out of scope for this contract slice.
    let revealedConnectedMatchers: [JSONValue]
    /// A `Direction`-keyed map of grid-adjacent location ids. Broad and out of scope for
    /// this contract slice (empty for every non-grid scenario, including this fixture's
    /// Night of the Zealot board).
    let directions: [JSONValue]
    let connectsTo: [GridDirection]
    /// Cards physically stacked underneath this location. Broad card union, out of scope
    /// for this contract slice.
    let cardsUnderneath: [JSONValue]
    /// `LocationAttrs.locationCostToEnterUnrevealed` (`Cost`, always present, not `Maybe`).
    let costToEnterUnrevealed: RuntimeCost
    let canBeFlipped: Bool
    let investigateSkill: Skill
    let placement: Placement?
    /// Arkham keys placed on this location. Broad, out of scope for this contract slice.
    let keys: [JSONValue]
    /// Scarlet Keys campaign seals placed on this location. Broad, out of scope for this
    /// contract slice.
    let seals: [JSONValue]
    let sealedChaosTokens: [ChaosToken]
    let placedChaosTokens: [ChaosToken]
    /// Edge of the Earth flood-level marker. Broad, out of scope for this contract slice.
    let floodLevel: JSONValue
    /// Edge of the Earth brazier state. Broad, out of scope for this contract slice.
    let brazier: JSONValue
    /// Breach/collapse status. Broad, out of scope for this contract slice.
    let breaches: JSONValue
    let withoutClues: Bool
    /// Free-form per-location scenario metadata.
    let meta: JSONValue
    /// Free-form shared scenario metadata, keyed by arbitrary string keys.
    let globalMeta: JSONValue
    /// The grid position, when this location is placed on a grid-based board. Broad, out
    /// of scope for this contract slice.
    let position: JSONValue
    let beingRemoved: Bool
    /// Concealed-card ids hidden at this location. Broad, out of scope for this contract
    /// slice.
    let concealedCards: [JSONValue]
    let outOfGame: Bool
    let connectedLocations: [LocationID]
    let investigators: [InvestigatorID]
    let enemies: [EnemyID]
    let assets: [AssetID]
    let events: [EventID]
    let treacheries: [TreacheryID]
    let scarletKeys: [CardCode]
    /// Active modifiers targeting this location. Broad and additive, out of scope for
    /// this contract slice.
    let modifiers: [JSONValue]
}

extension OrdinaryLocation: Equatable, Hashable {}

extension OrdinaryLocation: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case cardCode
        case cardID = "cardId"
        case label
        case revealClues
        case tokens
        case shroud
        case revealed
        case symbol
        case revealedSymbol
        case connectedMatchers
        case revealedConnectedMatchers
        case directions
        case connectsTo
        case cardsUnderneath
        case costToEnterUnrevealed
        case canBeFlipped
        case investigateSkill
        case placement
        case keys
        case seals
        case sealedChaosTokens
        case placedChaosTokens
        case floodLevel
        case brazier
        case breaches
        case withoutClues
        case meta
        case globalMeta
        case position
        case beingRemoved
        case concealedCards
        case outOfGame
        case connectedLocations
        case investigators
        case enemies
        case assets
        case events
        case treacheries
        case scarletKeys
        case modifiers
    }

    // swiftlint:disable:next function_body_length
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(LocationID.self, forKey: .id)
        cardCode = try container.decode(CardCode.self, forKey: .cardCode)
        cardID = try container.decode(WireCardID.self, forKey: .cardID)
        label = try container.decode(String.self, forKey: .label)
        revealClues = try container.decode(GameValue.self, forKey: .revealClues)
        tokens = try container.decode([TokenCount].self, forKey: .tokens)
        shroud = try decodeRequiredNullable(
            GameValue.self,
            from: container,
            forKey: .shroud,
            codingPath: decoder.codingPath
        )
        revealed = try container.decode(Bool.self, forKey: .revealed)
        symbol = try container.decode(LocationSymbol.self, forKey: .symbol)
        revealedSymbol = try container.decode(LocationSymbol.self, forKey: .revealedSymbol)
        connectedMatchers = try container.decode([JSONValue].self, forKey: .connectedMatchers)
        revealedConnectedMatchers = try container.decode(
            [JSONValue].self,
            forKey: .revealedConnectedMatchers
        )
        directions = try container.decode([JSONValue].self, forKey: .directions)
        connectsTo = try container.decode([GridDirection].self, forKey: .connectsTo)
        cardsUnderneath = try container.decode([JSONValue].self, forKey: .cardsUnderneath)
        costToEnterUnrevealed = try container.decode(
            RuntimeCost.self,
            forKey: .costToEnterUnrevealed
        )
        canBeFlipped = try container.decode(Bool.self, forKey: .canBeFlipped)
        investigateSkill = try container.decode(Skill.self, forKey: .investigateSkill)
        placement = try decodeRequiredNullable(
            Placement.self,
            from: container,
            forKey: .placement,
            codingPath: decoder.codingPath
        )
        keys = try container.decode([JSONValue].self, forKey: .keys)
        seals = try container.decode([JSONValue].self, forKey: .seals)
        sealedChaosTokens = try container.decode([ChaosToken].self, forKey: .sealedChaosTokens)
        placedChaosTokens = try container.decode([ChaosToken].self, forKey: .placedChaosTokens)
        floodLevel = try container.decode(JSONValue.self, forKey: .floodLevel)
        brazier = try container.decode(JSONValue.self, forKey: .brazier)
        breaches = try container.decode(JSONValue.self, forKey: .breaches)
        withoutClues = try container.decode(Bool.self, forKey: .withoutClues)
        meta = try container.decode(JSONValue.self, forKey: .meta)
        globalMeta = try container.decode(JSONValue.self, forKey: .globalMeta)
        position = try container.decode(JSONValue.self, forKey: .position)
        beingRemoved = try container.decode(Bool.self, forKey: .beingRemoved)
        concealedCards = try container.decode([JSONValue].self, forKey: .concealedCards)
        outOfGame = try container.decode(Bool.self, forKey: .outOfGame)
        connectedLocations = try container.decode([LocationID].self, forKey: .connectedLocations)
        investigators = try container.decode([InvestigatorID].self, forKey: .investigators)
        enemies = try container.decode([EnemyID].self, forKey: .enemies)
        assets = try container.decode([AssetID].self, forKey: .assets)
        events = try container.decode([EventID].self, forKey: .events)
        treacheries = try container.decode([TreacheryID].self, forKey: .treacheries)
        scarletKeys = try container.decode([CardCode].self, forKey: .scarletKeys)
        modifiers = try container.decode([JSONValue].self, forKey: .modifiers)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(cardCode, forKey: .cardCode)
        try container.encode(cardID, forKey: .cardID)
        try container.encode(label, forKey: .label)
        try container.encode(revealClues, forKey: .revealClues)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(shroud, forKey: .shroud)
        try container.encode(revealed, forKey: .revealed)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(revealedSymbol, forKey: .revealedSymbol)
        try container.encode(connectedMatchers, forKey: .connectedMatchers)
        try container.encode(revealedConnectedMatchers, forKey: .revealedConnectedMatchers)
        try container.encode(directions, forKey: .directions)
        try container.encode(connectsTo, forKey: .connectsTo)
        try container.encode(cardsUnderneath, forKey: .cardsUnderneath)
        try container.encode(costToEnterUnrevealed, forKey: .costToEnterUnrevealed)
        try container.encode(canBeFlipped, forKey: .canBeFlipped)
        try container.encode(investigateSkill, forKey: .investigateSkill)
        try container.encode(placement, forKey: .placement)
        try container.encode(keys, forKey: .keys)
        try container.encode(seals, forKey: .seals)
        try container.encode(sealedChaosTokens, forKey: .sealedChaosTokens)
        try container.encode(placedChaosTokens, forKey: .placedChaosTokens)
        try container.encode(floodLevel, forKey: .floodLevel)
        try container.encode(brazier, forKey: .brazier)
        try container.encode(breaches, forKey: .breaches)
        try container.encode(withoutClues, forKey: .withoutClues)
        try container.encode(meta, forKey: .meta)
        try container.encode(globalMeta, forKey: .globalMeta)
        try container.encode(position, forKey: .position)
        try container.encode(beingRemoved, forKey: .beingRemoved)
        try container.encode(concealedCards, forKey: .concealedCards)
        try container.encode(outOfGame, forKey: .outOfGame)
        try container.encode(connectedLocations, forKey: .connectedLocations)
        try container.encode(investigators, forKey: .investigators)
        try container.encode(enemies, forKey: .enemies)
        try container.encode(assets, forKey: .assets)
        try container.encode(events, forKey: .events)
        try container.encode(treacheries, forKey: .treacheries)
        try container.encode(scarletKeys, forKey: .scarletKeys)
        try container.encode(modifiers, forKey: .modifiers)
    }
}
