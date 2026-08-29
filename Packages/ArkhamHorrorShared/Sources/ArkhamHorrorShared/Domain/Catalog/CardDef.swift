/// A card catalog entry, as returned by `GET /arkham/cards`, `/arkham/homebrew/cards`, and
/// `/arkham/card/{cardCode}`.
///
/// Every property name matches its JSON key exactly. Only `cardCode`, `name`, `cardType`,
/// and `art` are required by the contract, and the schema never declares them nullable, so
/// a missing key or an explicit `null` both fail to decode. Every other declared-type
/// property is optional and absent-only: the schema's own type union never includes
/// `null`, so while the key may be entirely missing, an explicit `null` is rejected rather
/// than silently treated the same as "absent" (see ``decodeAbsentOnly``). The 9 properties
/// the schema leaves entirely unconstrained (`{}`) instead use ``OptionalField``, which
/// preserves the absent/null/value distinction the schema does allow for them.
struct CardDef: Sendable {
    let cardCode: CardCode
    let name: CardName
    let revealedName: CardName?
    let cost: CardCost?
    let additionalCost: OptionalField<JSONValue>
    let level: Int?
    let cardType: CardType
    let cardSubType: CardSubType?
    let classSymbols: UniqueItemsArray<ClassSymbol>?
    let skills: [SkillIcon]?
    let cardTraits: UniqueItemsArray<String>?
    let revealedCardTraits: UniqueItemsArray<String>?
    let keywords: [JSONValue]?
    let fastWindow: OptionalField<JSONValue>
    let actions: OptionalField<JSONValue>
    let revelation: Revelation?
    let victoryPoints: Int?
    let vengeancePoints: Int?
    let criteria: OptionalField<JSONValue>
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
    let uses: OptionalField<JSONValue>
    let playableFromDiscard: Bool?
    let stage: Int?
    let slots: [SlotType]?
    let alternateCardCodes: [CardCode]?
    let art: ArtworkIdentifier
    let locationSymbol: OptionalField<JSONValue>
    let locationRevealedSymbol: OptionalField<JSONValue>
    let locationConnections: [JSONValue]?
    let locationRevealedConnections: [JSONValue]?
    let purchaseTrauma: OptionalField<JSONValue>
    let grantedXp: Int?
    let canReplace: Bool?
    let deckRestrictions: [JSONValue]?
    let bondedWith: [BondedCardEntry]?
    let skipPlayWindows: Bool?
    let beforeEffect: Bool?
    let customizations: OptionalField<JSONValue>
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

extension CardDef: Equatable {}

/// A list of ``CardDef``, as returned by `GET /arkham/cards` and `/arkham/homebrew/cards`.
typealias CardList = [CardDef]

/// Card codes for investigators with dedicated artwork, as returned by
/// `GET /arkham/investigators`.
typealias InvestigatorArtwork = [ArtworkIdentifier]
