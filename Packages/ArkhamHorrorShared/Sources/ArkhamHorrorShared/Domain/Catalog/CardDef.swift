/// A card catalog entry, as returned by `GET /arkham/cards`, `/arkham/homebrew/cards`, and
/// `/arkham/card/{cardCode}`.
///
/// Every property name matches its JSON key exactly, so `Codable` conformance is fully
/// synthesized: no custom `init(from:)`/`encode(to:)` is needed. Only `cardCode`, `name`,
/// `cardType`, and `art` are required by the contract; every other property is optional and
/// absent when the card doesn't use it. Fields the schema leaves unconstrained (for example
/// `criteria`, `customizations`) are typed ``JSONValue``, never `Any`.
struct CardDef: Sendable, Equatable, Codable {
    let cardCode: CardCode
    let name: CardName
    let revealedName: CardName?
    let cost: CardCost?
    let additionalCost: JSONValue?
    let level: Int?
    let cardType: CardType
    let cardSubType: CardSubType?
    let classSymbols: Set<ClassSymbol>?
    let skills: [SkillIcon]?
    let cardTraits: Set<String>?
    let revealedCardTraits: Set<String>?
    let keywords: [JSONValue]?
    let fastWindow: JSONValue?
    let actions: JSONValue?
    let revelation: Revelation?
    let victoryPoints: Int?
    let vengeancePoints: Int?
    let criteria: JSONValue?
    let overrideActionPlayableIfCriteriaMet: Bool?
    let commitRestrictions: [JSONValue]?
    let attackOfOpportunityModifiers: [JSONValue]?
    let permanent: Bool?
    let encounterSet: String?
    let encounterSetQuantity: Int?
    let unique: Bool?
    let doubleSided: Bool?
    let limits: [JSONValue]?
    let exceptional: Bool?
    let uses: JSONValue?
    let playableFromDiscard: Bool?
    let stage: Int?
    let slots: [SlotType]?
    let alternateCardCodes: [CardCode]?
    let art: String
    let locationSymbol: JSONValue?
    let locationRevealedSymbol: JSONValue?
    let locationConnections: [JSONValue]?
    let locationRevealedConnections: [JSONValue]?
    let purchaseTrauma: JSONValue?
    let grantedXp: Int?
    let canReplace: Bool?
    let deckRestrictions: [JSONValue]?
    let bondedWith: [BondedCardEntry]?
    let skipPlayWindows: Bool?
    let beforeEffect: Bool?
    let customizations: JSONValue?
    let otherSide: CardCode?
    let whenDiscarded: WhenDiscarded?
    let canCommitWhenNoIcons: Bool?
    let commitTrigger: Bool?
    let meta: [String: JSONValue]?
    let tags: [String]?
    let outOfPlayEffects: [OutOfPlayEffect]?
    let health: GameValue?
    let fight: GameValue?
    let evade: GameValue?
    let healthDamage: GameValue?
    let sanityDamage: GameValue?
    let alternateSkills: [String: [SkillIcon]]?
    let alternateErrata: [String: String]?
    let errata: String?
}

/// A list of ``CardDef``, as returned by `GET /arkham/cards` and `/arkham/homebrew/cards`.
typealias CardList = [CardDef]

/// Card codes for investigators with dedicated artwork, as returned by
/// `GET /arkham/investigators`.
typealias InvestigatorArtwork = [String]
