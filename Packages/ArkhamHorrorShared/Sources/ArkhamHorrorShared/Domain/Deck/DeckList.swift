/// The normalized, backend-canonical deck list shape: all nine keys are always present,
/// `slots`/`sideSlots` keys are validated `CardCode`s, and `investigatorCode` is a validated
/// `CardCode`-patterned string.
struct DeckList: Sendable, Equatable {
    let slots: CardQuantityMap
    let sideSlots: CardQuantityMap
    let investigatorCode: CardCode
    let investigatorName: String
    let meta: String?
    let tabooId: Int?
    let url: String?
    let id: String?
    let name: String?
}

extension DeckList: Codable {
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
        slots = try container.decode(CardQuantityMap.self, forKey: .slots)
        sideSlots = try container.decode(CardQuantityMap.self, forKey: .sideSlots)
        investigatorCode = try container.decode(CardCode.self, forKey: .investigatorCode)
        investigatorName = try container.decode(String.self, forKey: .investigatorName)
        meta = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .meta,
            codingPath: decoder.codingPath
        )
        tabooId = try decodeRequiredNullable(
            Int.self,
            from: container,
            forKey: .tabooId,
            codingPath: decoder.codingPath
        )
        url = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .url,
            codingPath: decoder.codingPath
        )
        id = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .id,
            codingPath: decoder.codingPath
        )
        name = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .name,
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slots, forKey: .slots)
        try container.encode(sideSlots, forKey: .sideSlots)
        try container.encode(investigatorCode, forKey: .investigatorCode)
        try container.encode(investigatorName, forKey: .investigatorName)
        // Non-`IfPresent` encode so `nil` produces an explicit `null` rather than omitting
        // the key, matching the always-present wire shape.
        try container.encode(meta, forKey: .meta)
        try container.encode(tabooId, forKey: .tabooId)
        try container.encode(url, forKey: .url)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
    }
}
