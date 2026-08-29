/// An investigator entity as published in `PublicGame.investigators`/
/// `.otherInvestigators`/`.killedInvestigators` (`Arkham.Investigator.Types
/// .InvestigatorAttrs`, merged with per-connection `HasGame` data such as
/// `connectedLocations`). Deck/hand/discard card-union payloads, ability/action
/// bookkeeping, campaign log, and slot layout remain intentionally broad in this contract
/// slice; only the top-level field set, ids, and scalar stats are asserted exactly.
struct Investigator: Sendable {
    /// Actions performed this round, keyed by action type. Broad, out of scope for this
    /// contract slice.
    let actionsPerformed: [JSONValue]
    /// Actions taken this turn. Broad, out of scope for this contract slice.
    let actionsTaken: [JSONValue]
    /// Additional-action grants currently available. Broad, out of scope for this
    /// contract slice.
    let additionalActions: [JSONValue]
    let agility: Int
    /// The card art/back code, usually equal to `cardCode`.
    let art: String
    let assets: [AssetID]
    let assignedHealthDamage: Int
    /// Pending health-heal assignments. Broad, out of scope for this contract slice.
    let assignedHealthHeal: [JSONValue]
    let assignedSanityDamage: Int
    /// Pending sanity-heal assignments. Broad, out of scope for this contract slice.
    let assignedSanityHeal: [JSONValue]
    /// `Maybe LocationId` recorded at the start of this investigator's turn.
    let beganRoundAt: LocationID?
    /// Bonded cards attached to this investigator. Broad card union, out of scope for
    /// this contract slice.
    let bondedCards: [JSONValue]
    let cardCode: CardCode
    /// Cards physically stacked underneath this investigator. Broad card union, out of
    /// scope for this contract slice.
    let cardsUnderneath: [JSONValue]
    let investigatorClass: ClassSymbol
    let combat: Int
    let connectedLocations: [LocationID]
    /// Remaining deck cards. Broad card union, out of scope for this contract slice.
    let deck: [JSONValue]
    /// Deckbuilding option adjustments. Broad, out of scope for this contract slice.
    let deckBuildingAdjustments: [JSONValue]
    let deckSize: Int
    let deckURL: String?
    /// Named side decks (for example bonded/spectral decks). Broad, out of scope for
    /// this contract slice.
    let decks: [JSONValue]
    let defeated: Bool
    /// Discarded cards. Broad card union, out of scope for this contract slice.
    let discard: [JSONValue]
    /// In-progress discard state, if any. Broad, out of scope for this contract slice.
    let discarding: JSONValue?
    /// In-progress clue-discovery state, if any. Broad, out of scope for this contract
    /// slice.
    let discover: JSONValue?
    /// In-progress card-draw state, if any. Broad, out of scope for this contract slice.
    let drawing: JSONValue?
    /// Cards drawn so far this draw step. Broad card union, out of scope for this
    /// contract slice.
    let drawnCards: [JSONValue]
    let drivenInsane: Bool
    let eliminated: Bool
    let endedTurn: Bool
    let engagedEnemies: [EnemyID]
    let events: [EventID]
    /// Cards excluded from the opening mulligan. Broad card union, out of scope for this
    /// contract slice.
    let excludeFromMulligan: [JSONValue]
    /// The investigator's current alternate-form state, if any (for example
    /// transformation cards). Broad tagged union beyond its tag, out of scope for this
    /// contract slice.
    let form: JSONValue
    /// Free-form alternate-form metadata.
    let formMeta: JSONValue
    /// Cards currently in hand. Broad card union, out of scope for this contract slice.
    let hand: [JSONValue]
    let handSize: Int
    let health: Int
    let horrorHealed: Int
    let id: InvestigatorID
    let intellect: Int
    /// Arkham keys held by this investigator. Broad, out of scope for this contract
    /// slice.
    let keys: [JSONValue]
    let killed: Bool
    /// Per-investigator recorded campaign log entries. Broad, out of scope for this
    /// contract slice.
    let log: JSONValue
    let mentalTrauma: Int
    /// Free-form per-investigator scenario metadata.
    let meta: JSONValue
    /// Active modifiers targeting this investigator. Broad and additive, out of scope
    /// for this contract slice.
    let modifiers: [JSONValue]
    /// `InvestigatorAttrs.investigatorMovement` (`Maybe Movement`): the in-progress move
    /// this investigator is currently mid-resolving, if any.
    let movement: Movement?
    let mulligansTaken: Int
    /// An overriding mutated card code, if any.
    let mutated: JSONValue
    let name: CardName
    let physicalTrauma: Int
    let placement: Placement
    let playerID: PlayerID
    /// `Maybe LocationId` this investigator moved from most recently.
    let previousLocation: LocationID?
    let remainingActions: Int
    let resigned: Bool
    let sanity: Int
    /// `ScarletKeyId` (`CardCode`-backed) values held by this investigator.
    let scarletKeys: [CardCode]
    let sealedChaosTokens: [ChaosToken]
    /// Scarlet Keys campaign seals placed on this investigator. Broad, out of scope for
    /// this contract slice.
    let seals: [JSONValue]
    /// In-progress search state, if any. Broad, out of scope for this contract slice.
    let search: JSONValue?
    /// Per-investigator UI/rules settings (global and per-card overrides). Broad, out of
    /// scope for this contract slice.
    let settings: JSONValue
    /// A named side deck reference, if any. Broad, out of scope for this contract slice.
    let sideDeck: JSONValue
    let skills: [SkillID]
    let skippedWindow: Bool
    /// The investigator's asset slot layout and current occupants, encoded as an array of
    /// `[slotType, slots]` pairs. Broad, out of scope for this contract slice.
    let slots: [JSONValue]
    let spentXp: Int
    /// Cards this investigator's deck must start with. Broad card union, out of scope
    /// for this contract slice.
    let startsWith: [JSONValue]
    /// Cards that start in this investigator's opening hand. Broad card union, out of
    /// scope for this contract slice.
    let startsWithInHand: [JSONValue]
    /// Campaign supply cards. Broad, out of scope for this contract slice.
    let supplies: [JSONValue]
    /// The applied taboo list id, if any.
    let taboo: JSONValue
    let tokens: [TokenCount]
    /// An open, additive string set of card traits (for example Agency, Detective). Not
    /// a closed enum.
    let traits: [String]
    let treacheries: [TreacheryID]
    /// Can go negative: healing (`Runner/Damage.hs`'s `min 0 . subtract amount`) clamps
    /// the *upper* bound at 0 but not the lower one, so healing more horror in a round
    /// than was actually assigned genuinely produces a negative wire value. This models
    /// current production behavior, not an intentionally-designed range.
    let unhealedHorrorThisRound: Int
    /// Abilities used and their remaining-use bookkeeping. Broad, out of scope for this
    /// contract slice.
    let usedAbilities: [JSONValue]
    /// Additional-action grants already consumed. Broad, out of scope for this contract
    /// slice.
    let usedAdditionalActions: [JSONValue]
    let willpower: Int
    let experiencePoints: Int
}

extension Investigator: Equatable, Hashable {}
