/// Phantom tag distinguishing ``ActSide``.
enum ActSideTag: Sendable {}
/// `Arkham.Act.Sequence.ActSide` (`Act/Sequence.hs`), nullary-only so Aeson's
/// `allNullaryToStringTag` applies and it encodes as a bare string tag.
typealias ActSide = OpenStringEnum<ActSideTag>

extension ActSide {
    static let sideA = ActSide("A")
    static let sideB = ActSide("B")
    static let sideC = ActSide("C")
    static let sideD = ActSide("D")
    static let sideE = ActSide("E")
    static let sideF = ActSide("F")
    static let sideG = ActSide("G")
    static let sideH = ActSide("H")
}

/// `ActAttrs.actSequence`'s `[step, side]` pair, for example `[1, "A"]`.
struct ActSequence: Sendable {
    let step: Int
    let side: ActSide
}

extension ActSequence: Equatable, Hashable {}

extension ActSequence: Codable {
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        step = try container.decode(Int.self)
        side = try container.decode(ActSide.self)
        guard container.isAtEnd else {
            let context = DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Expected exactly 2 elements for ActSequence"
            )
            throw DecodingError.dataCorrupted(context)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(step)
        try container.encode(side)
    }
}

/// An act entity as published in `PublicGame.acts` (`Arkham.Act.Types.ActAttrs`).
/// Advancement-cost, key, and card-union payloads remain intentionally broad.
struct Act: Sendable {
    let id: ActID
    let cardID: WireCardID
    let sequence: ActSequence
    let deckID: Int
    let flipped: Bool
    /// `ActAttrs.actAdvanceCost` (`Maybe Cost`).
    let advanceCost: RuntimeCost?
    /// Scarlet Keys campaign breach count. Broad, out of scope for this contract slice.
    let breaches: JSONValue
    /// Cards physically stacked underneath this act. Broad card union, out of scope for
    /// this contract slice.
    let cardsUnderneath: [JSONValue]
    /// Arkham keys placed on this act. Broad, out of scope for this contract slice.
    let keys: [JSONValue]
    /// Free-form per-act scenario metadata.
    let meta: JSONValue
    /// Active modifiers targeting this act. Broad and additive, out of scope for this
    /// contract slice.
    let modifiers: [JSONValue]
    let tokens: [TokenCount]
    /// `TreacheryId` (UUID) values attached to this act.
    let treacheries: [TreacheryID]
    let usedWheelOfFortuneX: Bool
}

extension Act: Equatable, Hashable {}

extension Act: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case cardID = "cardId"
        case sequence
        case deckID = "deckId"
        case flipped
        case advanceCost
        case breaches
        case cardsUnderneath
        case keys
        case meta
        case modifiers
        case tokens
        case treacheries
        case usedWheelOfFortuneX
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ActID.self, forKey: .id)
        cardID = try container.decode(WireCardID.self, forKey: .cardID)
        sequence = try container.decode(ActSequence.self, forKey: .sequence)
        deckID = try container.decode(Int.self, forKey: .deckID)
        flipped = try container.decode(Bool.self, forKey: .flipped)
        advanceCost = try decodeRequiredNullable(
            RuntimeCost.self,
            from: container,
            forKey: .advanceCost,
            codingPath: decoder.codingPath + [CodingKeys.advanceCost]
        )
        breaches = try container.decode(JSONValue.self, forKey: .breaches)
        cardsUnderneath = try container.decode([JSONValue].self, forKey: .cardsUnderneath)
        keys = try container.decode([JSONValue].self, forKey: .keys)
        meta = try container.decode(JSONValue.self, forKey: .meta)
        modifiers = try container.decode([JSONValue].self, forKey: .modifiers)
        tokens = try container.decode([TokenCount].self, forKey: .tokens)
        treacheries = try container.decode([TreacheryID].self, forKey: .treacheries)
        usedWheelOfFortuneX = try container.decode(Bool.self, forKey: .usedWheelOfFortuneX)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(cardID, forKey: .cardID)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(deckID, forKey: .deckID)
        try container.encode(flipped, forKey: .flipped)
        try container.encode(advanceCost, forKey: .advanceCost)
        try container.encode(breaches, forKey: .breaches)
        try container.encode(cardsUnderneath, forKey: .cardsUnderneath)
        try container.encode(keys, forKey: .keys)
        try container.encode(meta, forKey: .meta)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(treacheries, forKey: .treacheries)
        try container.encode(usedWheelOfFortuneX, forKey: .usedWheelOfFortuneX)
    }
}
