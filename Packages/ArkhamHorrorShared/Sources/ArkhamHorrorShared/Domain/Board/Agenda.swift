/// Phantom tag distinguishing ``AgendaSide``.
enum AgendaSideTag: Sendable {}
/// `Arkham.Agenda.Sequence.AgendaSide` (`Agenda/Sequence.hs`), nullary-only so Aeson's
/// `allNullaryToStringTag` applies and it encodes as a bare string tag.
typealias AgendaSide = OpenStringEnum<AgendaSideTag>

extension AgendaSide {
    static let sideA = AgendaSide("A")
    static let sideB = AgendaSide("B")
    static let sideC = AgendaSide("C")
    static let sideD = AgendaSide("D")
}

/// `AgendaAttrs.agendaSequence`, an object pair of side and step (unlike ``ActSequence``'s
/// array encoding).
struct AgendaSequence: Sendable {
    let side: AgendaSide
    let step: Int
}

extension AgendaSequence: Equatable, Hashable {}

extension AgendaSequence: Codable {
    private enum CodingKeys: String, CodingKey {
        case side = "agendaSequenceSide"
        case step = "agendaSequenceStep"
    }
}

/// An agenda entity as published in `PublicGame.agendas`
/// (`Arkham.Agenda.Types.AgendaAttrs`). Doom-remover-matcher and card-union payloads
/// remain intentionally broad.
struct Agenda: Sendable {
    let id: AgendaID
    let cardID: WireCardID
    let sequence: AgendaSequence
    let deckID: Int
    let doom: Int
    let doomThreshold: GameValue?
    let flipped: Bool
    /// Cards physically stacked underneath this agenda. Broad card union, out of scope
    /// for this contract slice.
    let cardsUnderneath: [JSONValue]
    /// Free-form per-agenda scenario metadata.
    let meta: JSONValue
    /// Active modifiers targeting this agenda. Broad and additive, out of scope for this
    /// contract slice.
    let modifiers: [JSONValue]
    /// The act/agenda matchers governing where a doom removal effect applies. Broad, out
    /// of scope for this contract slice.
    let removeDoomMatchers: JSONValue
    let tokens: [TokenCount]
    /// `TreacheryId` (UUID) values attached to this agenda.
    let treacheries: [TreacheryID]
    let usedWheelOfFortuneX: Bool
}

extension Agenda: Equatable, Hashable {}

extension Agenda: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case cardID = "cardId"
        case sequence
        case deckID = "deckId"
        case doom
        case doomThreshold
        case flipped
        case cardsUnderneath
        case meta
        case modifiers
        case removeDoomMatchers
        case tokens
        case treacheries
        case usedWheelOfFortuneX
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AgendaID.self, forKey: .id)
        cardID = try container.decode(WireCardID.self, forKey: .cardID)
        sequence = try container.decode(AgendaSequence.self, forKey: .sequence)
        deckID = try container.decode(Int.self, forKey: .deckID)
        doom = try container.decode(Int.self, forKey: .doom)
        doomThreshold = try decodeRequiredNullable(
            GameValue.self,
            from: container,
            forKey: .doomThreshold,
            codingPath: decoder.codingPath
        )
        flipped = try container.decode(Bool.self, forKey: .flipped)
        cardsUnderneath = try container.decode([JSONValue].self, forKey: .cardsUnderneath)
        meta = try container.decode(JSONValue.self, forKey: .meta)
        modifiers = try container.decode([JSONValue].self, forKey: .modifiers)
        removeDoomMatchers = try container.decode(JSONValue.self, forKey: .removeDoomMatchers)
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
        try container.encode(doom, forKey: .doom)
        try container.encode(doomThreshold, forKey: .doomThreshold)
        try container.encode(flipped, forKey: .flipped)
        try container.encode(cardsUnderneath, forKey: .cardsUnderneath)
        try container.encode(meta, forKey: .meta)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(removeDoomMatchers, forKey: .removeDoomMatchers)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(treacheries, forKey: .treacheries)
        try container.encode(usedWheelOfFortuneX, forKey: .usedWheelOfFortuneX)
    }
}
