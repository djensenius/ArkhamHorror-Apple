/// `CardDef`'s `Codable` conformance. Kept in its own file (separate from the type
/// declaration in `CardDef.swift`) purely to stay under SwiftLint's file-length limit: with
/// 62 top-level properties, the decode/encode logic for all of them is inherently large.
extension CardDef: Codable {
    enum CodingKeys: String, CodingKey {
        case cardCode
        case name
        case revealedName
        case cost
        case additionalCost
        case level
        case cardType
        case cardSubType
        case classSymbols
        case skills
        case cardTraits
        case revealedCardTraits
        case keywords
        case fastWindow
        case actions
        case revelation
        case victoryPoints
        case vengeancePoints
        case criteria
        case overrideActionPlayableIfCriteriaMet
        case commitRestrictions
        case attackOfOpportunityModifiers
        case permanent
        case encounterSet
        case encounterSetQuantity
        case unique
        case doubleSided
        case limits
        case exceptional
        case uses
        case playableFromDiscard
        case stage
        case slots
        case alternateCardCodes
        case art
        case locationSymbol
        case locationRevealedSymbol
        case locationConnections
        case locationRevealedConnections
        case purchaseTrauma
        case grantedXp
        case canReplace
        case deckRestrictions
        case bondedWith
        case skipPlayWindows
        case beforeEffect
        case customizations
        case otherSide
        case whenDiscarded
        case canCommitWhenNoIcons
        case commitTrigger
        case meta
        case tags
        case outOfPlayEffects
        case health
        case fight
        case evade
        case healthDamage
        case sanityDamage
        case alternateSkills
        case alternateErrata
        case errata
    }

    // The 62 top-level `CardDef` properties are decoded/encoded via 4
    // mechanically-split parts (`DecodedPart1`-`DecodedPart4`) purely to keep
    // `init(from:)`/`encode(to:)` under SwiftLint's function-length limit; the
    // split does not reflect any meaningful domain grouping, just declaration order.
    private struct DecodedPart1: Sendable {
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
    }

    private struct DecodedPart2: Sendable {
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
    }

    private struct DecodedPart3: Sendable {
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
    }

    private struct DecodedPart4: Sendable {
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

    private static func decodePart1(
        container: KeyedDecodingContainer<CodingKeys>,
        path: [any CodingKey]
    ) throws -> DecodedPart1 {
        func absentOnly<Value: Decodable>(_ type: Value.Type, _ key: CodingKeys) throws -> Value? {
            try decodeAbsentOnly(type, from: container, forKey: key, codingPath: path)
        }
        func optionalField(_ key: CodingKeys) throws -> OptionalField<JSONValue> {
            try OptionalField<JSONValue>.decode(from: container, forKey: key)
        }
        return try DecodedPart1(
            cardCode: container.decode(CardCode.self, forKey: .cardCode),
            name: container.decode(CardName.self, forKey: .name),
            revealedName: absentOnly(CardName.self, .revealedName),
            cost: absentOnly(CardCost.self, .cost),
            additionalCost: optionalField(.additionalCost),
            level: absentOnly(Int.self, .level),
            cardType: container.decode(CardType.self, forKey: .cardType),
            cardSubType: absentOnly(CardSubType.self, .cardSubType),
            classSymbols: absentOnly(UniqueItemsArray<ClassSymbol>.self, .classSymbols),
            skills: absentOnly([SkillIcon].self, .skills),
            cardTraits: absentOnly(UniqueItemsArray<String>.self, .cardTraits),
            revealedCardTraits: absentOnly(UniqueItemsArray<String>.self, .revealedCardTraits),
            keywords: absentOnly([JSONValue].self, .keywords),
            fastWindow: optionalField(.fastWindow),
            actions: optionalField(.actions),
            revelation: absentOnly(Revelation.self, .revelation)
        )
    }

    private static func decodePart2(
        container: KeyedDecodingContainer<CodingKeys>,
        path: [any CodingKey]
    ) throws -> DecodedPart2 {
        func absentOnly<Value: Decodable>(_ type: Value.Type, _ key: CodingKeys) throws -> Value? {
            try decodeAbsentOnly(type, from: container, forKey: key, codingPath: path)
        }
        func optionalField(_ key: CodingKeys) throws -> OptionalField<JSONValue> {
            try OptionalField<JSONValue>.decode(from: container, forKey: key)
        }
        return try DecodedPart2(
            victoryPoints: absentOnly(Int.self, .victoryPoints),
            vengeancePoints: absentOnly(Int.self, .vengeancePoints),
            criteria: optionalField(.criteria),
            overrideActionPlayableIfCriteriaMet: absentOnly(
                Bool.self, .overrideActionPlayableIfCriteriaMet
            ),
            commitRestrictions: absentOnly([JSONValue].self, .commitRestrictions),
            attackOfOpportunityModifiers: absentOnly(
                [JSONValue].self, .attackOfOpportunityModifiers
            ),
            permanent: absentOnly(Bool.self, .permanent),
            encounterSet: absentOnly(String.self, .encounterSet),
            encounterSetQuantity: absentOnly(Int.self, .encounterSetQuantity),
            unique: absentOnly(Bool.self, .unique),
            doubleSided: absentOnly(Bool.self, .doubleSided),
            limits: absentOnly([JSONValue].self, .limits),
            exceptional: absentOnly(Bool.self, .exceptional),
            uses: optionalField(.uses),
            playableFromDiscard: absentOnly(Bool.self, .playableFromDiscard),
            stage: absentOnly(Int.self, .stage)
        )
    }

    private static func decodePart3(
        container: KeyedDecodingContainer<CodingKeys>,
        path: [any CodingKey]
    ) throws -> DecodedPart3 {
        func absentOnly<Value: Decodable>(_ type: Value.Type, _ key: CodingKeys) throws -> Value? {
            try decodeAbsentOnly(type, from: container, forKey: key, codingPath: path)
        }
        func optionalField(_ key: CodingKeys) throws -> OptionalField<JSONValue> {
            try OptionalField<JSONValue>.decode(from: container, forKey: key)
        }
        return try DecodedPart3(
            slots: absentOnly([SlotType].self, .slots),
            alternateCardCodes: absentOnly([CardCode].self, .alternateCardCodes),
            art: container.decode(ArtworkIdentifier.self, forKey: .art),
            locationSymbol: optionalField(.locationSymbol),
            locationRevealedSymbol: optionalField(.locationRevealedSymbol),
            locationConnections: absentOnly([JSONValue].self, .locationConnections),
            locationRevealedConnections: absentOnly([JSONValue].self, .locationRevealedConnections),
            purchaseTrauma: optionalField(.purchaseTrauma),
            grantedXp: absentOnly(Int.self, .grantedXp),
            canReplace: absentOnly(Bool.self, .canReplace),
            deckRestrictions: absentOnly([JSONValue].self, .deckRestrictions),
            bondedWith: absentOnly([BondedCardEntry].self, .bondedWith),
            skipPlayWindows: absentOnly(Bool.self, .skipPlayWindows),
            beforeEffect: absentOnly(Bool.self, .beforeEffect),
            customizations: optionalField(.customizations)
        )
    }

    private static func decodePart4(
        container: KeyedDecodingContainer<CodingKeys>,
        path: [any CodingKey]
    ) throws -> DecodedPart4 {
        func absentOnly<Value: Decodable>(_ type: Value.Type, _ key: CodingKeys) throws -> Value? {
            try decodeAbsentOnly(type, from: container, forKey: key, codingPath: path)
        }
        func optionalField(_ key: CodingKeys) throws -> OptionalField<JSONValue> {
            try OptionalField<JSONValue>.decode(from: container, forKey: key)
        }
        return try DecodedPart4(
            otherSide: absentOnly(CardCode.self, .otherSide),
            whenDiscarded: absentOnly(WhenDiscarded.self, .whenDiscarded),
            canCommitWhenNoIcons: absentOnly(Bool.self, .canCommitWhenNoIcons),
            commitTrigger: absentOnly(Bool.self, .commitTrigger),
            meta: absentOnly([String: JSONValue].self, .meta),
            tags: absentOnly([String].self, .tags),
            outOfPlayEffects: absentOnly([OutOfPlayEffect].self, .outOfPlayEffects),
            health: absentOnly(GameValue.self, .health),
            fight: absentOnly(GameValue.self, .fight),
            evade: absentOnly(GameValue.self, .evade),
            healthDamage: absentOnly(GameValue.self, .healthDamage),
            sanityDamage: absentOnly(GameValue.self, .sanityDamage),
            alternateSkills: absentOnly([String: [SkillIcon]].self, .alternateSkills),
            alternateErrata: absentOnly([String: String].self, .alternateErrata),
            errata: absentOnly(String.self, .errata)
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = decoder.codingPath
        let part1 = try Self.decodePart1(container: container, path: path)
        let part2 = try Self.decodePart2(container: container, path: path)
        let part3 = try Self.decodePart3(container: container, path: path)
        let part4 = try Self.decodePart4(container: container, path: path)
        (cardCode, name, revealedName) = (part1.cardCode, part1.name, part1.revealedName)
        (cost, additionalCost, level) = (part1.cost, part1.additionalCost, part1.level)
        (cardType, cardSubType) = (part1.cardType, part1.cardSubType)
        (classSymbols, skills, cardTraits) = (part1.classSymbols, part1.skills, part1.cardTraits)
        (revealedCardTraits, keywords) = (part1.revealedCardTraits, part1.keywords)
        (fastWindow, actions, revelation) = (part1.fastWindow, part1.actions, part1.revelation)
        (victoryPoints, vengeancePoints) = (part2.victoryPoints, part2.vengeancePoints)
        criteria = part2.criteria
        overrideActionPlayableIfCriteriaMet = part2.overrideActionPlayableIfCriteriaMet
        commitRestrictions = part2.commitRestrictions
        attackOfOpportunityModifiers = part2.attackOfOpportunityModifiers
        (permanent, encounterSet) = (part2.permanent, part2.encounterSet)
        (encounterSetQuantity, unique) = (part2.encounterSetQuantity, part2.unique)
        (doubleSided, limits, exceptional) = (part2.doubleSided, part2.limits, part2.exceptional)
        (uses, playableFromDiscard, stage) = (part2.uses, part2.playableFromDiscard, part2.stage)
        (slots, alternateCardCodes, art) = (part3.slots, part3.alternateCardCodes, part3.art)
        locationSymbol = part3.locationSymbol
        locationRevealedSymbol = part3.locationRevealedSymbol
        locationConnections = part3.locationConnections
        locationRevealedConnections = part3.locationRevealedConnections
        (purchaseTrauma, grantedXp) = (part3.purchaseTrauma, part3.grantedXp)
        (canReplace, deckRestrictions) = (part3.canReplace, part3.deckRestrictions)
        (bondedWith, skipPlayWindows) = (part3.bondedWith, part3.skipPlayWindows)
        (beforeEffect, customizations) = (part3.beforeEffect, part3.customizations)
        (otherSide, whenDiscarded) = (part4.otherSide, part4.whenDiscarded)
        (canCommitWhenNoIcons, commitTrigger) = (part4.canCommitWhenNoIcons, part4.commitTrigger)
        (meta, tags, outOfPlayEffects) = (part4.meta, part4.tags, part4.outOfPlayEffects)
        (health, fight, evade) = (part4.health, part4.fight, part4.evade)
        (healthDamage, sanityDamage) = (part4.healthDamage, part4.sanityDamage)
        (alternateSkills, alternateErrata) = (part4.alternateSkills, part4.alternateErrata)
        errata = part4.errata
    }
}
