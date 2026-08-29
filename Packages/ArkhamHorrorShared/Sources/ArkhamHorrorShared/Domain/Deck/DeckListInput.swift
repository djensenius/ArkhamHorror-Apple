/// `DeckListInput.id`: an external identifier that may arrive as a JSON string, number, or
/// null, without precision loss for large numeric IDs.
enum ExternalID: Sendable {
    case string(String)
    case number(JSONNumber)
    case null
}

extension ExternalID: Equatable, Hashable {}

extension ExternalID: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = try .number(container.decode(JSONNumber.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

/// `DeckListInput.sideSlots`: the schema leaves this field's shape entirely unconstrained,
/// and documents that a production decoder silently normalizes malformed input to an empty
/// map server-side. The client model preserves what was actually on the wire instead of
/// pretending malformed data already is a normalized map.
enum DeckSideSlotsInput: Sendable {
    /// The key was absent.
    case absent
    /// The key decoded as a valid card-quantity map.
    case valid(CardQuantityMapInput)
    /// The key was present but did not decode as a card-quantity map (for example an array,
    /// a scalar, or an object with non-integer values).
    case malformed(JSONValue)
}

extension DeckSideSlotsInput: Equatable, Hashable {}

/// The permissive, externally-sourced deck list shape submitted by ArkhamDB-style deck
/// imports (`createDeckRequest.deckList`, `chooseDeckRequest.deckList`,
/// `validateDeckList`). Only `slots` and `investigatorCode` are required; every other field
/// may be absent, `null`, or (for `id`) a string or number.
struct DeckListInput: Sendable {
    let slots: CardQuantityMapInput
    let sideSlots: DeckSideSlotsInput
    let investigatorCode: InvestigatorCode
    let investigatorName: String?
    let meta: String?
    let tabooId: Int?
    let url: String?
    /// Absent (`nil`) is distinct from an explicit JSON `null` (`.some(.null)`).
    let id: ExternalID?
    let name: String?
}

extension DeckListInput: Equatable, Hashable {}

extension DeckListInput: Codable {
    private enum CodingKeys: String, CodingKey {
        case slots
        case sideSlots
        case investigatorCode = "investigator_code"
        case investigatorName = "investigator_name"
        case meta
        case tabooId = "taboo_id"
        case url
        case id
        case name
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slots = try container.decode(CardQuantityMapInput.self, forKey: .slots)
        if container.contains(.sideSlots) {
            if let map = try? container.decode(CardQuantityMapInput.self, forKey: .sideSlots) {
                sideSlots = .valid(map)
            } else {
                sideSlots = try .malformed(container.decode(JSONValue.self, forKey: .sideSlots))
            }
        } else {
            sideSlots = .absent
        }
        investigatorCode = try container.decode(InvestigatorCode.self, forKey: .investigatorCode)
        investigatorName = try container.decodeIfPresent(String.self, forKey: .investigatorName)
        meta = try container.decodeIfPresent(String.self, forKey: .meta)
        tabooId = try container.decodeIfPresent(Int.self, forKey: .tabooId)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        // A manual absent/null/value check: `decodeIfPresent` would collapse an explicit
        // `null` into the same `nil` as an absent key.
        if container.contains(.id) {
            if try container.decodeNil(forKey: .id) {
                id = .null
            } else {
                id = try container.decode(ExternalID.self, forKey: .id)
            }
        } else {
            id = nil
        }
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slots, forKey: .slots)
        switch sideSlots {
        case .absent:
            break
        case let .valid(map):
            try container.encode(map, forKey: .sideSlots)
        case let .malformed(value):
            try container.encode(value, forKey: .sideSlots)
        }
        try container.encode(investigatorCode, forKey: .investigatorCode)
        try container.encodeIfPresent(investigatorName, forKey: .investigatorName)
        try container.encodeIfPresent(meta, forKey: .meta)
        try container.encodeIfPresent(tabooId, forKey: .tabooId)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
    }
}
