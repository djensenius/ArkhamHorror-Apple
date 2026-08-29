/// Phantom tag distinguishing ``ClassSymbol``.
enum ClassSymbolTag: Sendable {}
/// An investigator class symbol. Shared verbatim between the catalog contract
/// (`CardDef.classSymbols`) and the game-list contract (`InvestigatorSummary.classSymbol`).
typealias ClassSymbol = OpenStringEnum<ClassSymbolTag>

extension ClassSymbol {
    static let guardian = ClassSymbol("Guardian")
    static let seeker = ClassSymbol("Seeker")
    static let survivor = ClassSymbol("Survivor")
    static let rogue = ClassSymbol("Rogue")
    static let mystic = ClassSymbol("Mystic")
    static let neutral = ClassSymbol("Neutral")
    static let mythos = ClassSymbol("Mythos")
}

/// Phantom tag distinguishing ``CardType``.
enum CardTypeTag: Sendable {}
/// A card's primary type, for example `AssetType` or `InvestigatorType`.
typealias CardType = OpenStringEnum<CardTypeTag>

extension CardType {
    static let asset = CardType("AssetType")
    static let event = CardType("EventType")
    static let skill = CardType("SkillType")
    static let playerTreachery = CardType("PlayerTreacheryType")
    static let playerEnemy = CardType("PlayerEnemyType")
    static let treachery = CardType("TreacheryType")
    static let enemy = CardType("EnemyType")
    static let location = CardType("LocationType")
    static let enemyLocation = CardType("EnemyLocationCardType")
    static let encounterAsset = CardType("EncounterAssetType")
    static let encounterEvent = CardType("EncounterEventType")
    static let act = CardType("ActType")
    static let agenda = CardType("AgendaType")
    static let story = CardType("StoryType")
    static let investigator = CardType("InvestigatorType")
    static let scenario = CardType("ScenarioType")
    static let key = CardType("KeyType")
}

/// Phantom tag distinguishing ``CardSubType``.
enum CardSubTypeTag: Sendable {}
/// A weakness sub-type, for example `Weakness` or `BasicWeakness`.
typealias CardSubType = OpenStringEnum<CardSubTypeTag>

extension CardSubType {
    static let weakness = CardSubType("Weakness")
    static let basicWeakness = CardSubType("BasicWeakness")
}

/// Phantom tag distinguishing ``SlotType``.
enum SlotTypeTag: Sendable {}
/// A card slot type consumed by asset cards, for example `HandSlot`.
typealias SlotType = OpenStringEnum<SlotTypeTag>

extension SlotType {
    static let hand = SlotType("HandSlot")
    static let body = SlotType("BodySlot")
    static let ally = SlotType("AllySlot")
    static let accessory = SlotType("AccessorySlot")
    static let arcane = SlotType("ArcaneSlot")
    static let tarot = SlotType("TarotSlot")
    static let head = SlotType("HeadSlot")
}

/// Phantom tag distinguishing ``Revelation``.
enum RevelationTag: Sendable {}
/// A treachery card's revelation behavior.
typealias Revelation = OpenStringEnum<RevelationTag>

extension Revelation {
    static let noRevelation = Revelation("NoRevelation")
    static let isRevelation = Revelation("IsRevelation")
    static let cannotBeCanceledRevelation = Revelation("CannotBeCanceledRevelation")
}

/// Phantom tag distinguishing ``WhenDiscarded``.
enum WhenDiscardedTag: Sendable {}
/// Where a card goes when discarded, for example `ToBonded`.
typealias WhenDiscarded = OpenStringEnum<WhenDiscardedTag>

extension WhenDiscarded {
    static let toDiscard = WhenDiscarded("ToDiscard")
    static let toBonded = WhenDiscarded("ToBonded")
    static let toSetAside = WhenDiscarded("ToSetAside")
}

/// Phantom tag distinguishing ``OutOfPlayEffect``.
enum OutOfPlayEffectTag: Sendable {}
/// An effect applied while a card sits outside of play, for example `InHandEffect`.
typealias OutOfPlayEffect = OpenStringEnum<OutOfPlayEffectTag>

extension OutOfPlayEffect {
    static let inHand = OutOfPlayEffect("InHandEffect")
    static let inDiscard = OutOfPlayEffect("InDiscardEffect")
    static let inSearch = OutOfPlayEffect("InSearchEffect")
    static let onTopOfDeck = OutOfPlayEffect("OnTopOfDeckEffect")
}

/// Phantom tag distinguishing ``Skill``.
enum SkillTag: Sendable {}
/// A skill test icon's underlying skill, for example `SkillWillpower`.
typealias Skill = OpenStringEnum<SkillTag>

extension Skill {
    static let willpower = Skill("SkillWillpower")
    static let intellect = Skill("SkillIntellect")
    static let combat = Skill("SkillCombat")
    static let agility = Skill("SkillAgility")
}
