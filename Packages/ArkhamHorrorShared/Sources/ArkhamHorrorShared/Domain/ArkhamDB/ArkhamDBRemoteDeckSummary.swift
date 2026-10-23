/// A remote deck summary, including this user's optional local mapping.
struct ArkhamDBRemoteDeckSummary: Sendable, Equatable {
    let id: String
    let name: String
    let url: String?
    let investigatorName: String?
    let lastUpdatedAt: String?
    let version: String?
    let linkedLocalDeckId: DeckID?
}

extension ArkhamDBRemoteDeckSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
        case investigatorName
        case lastUpdatedAt
        case version
        case linkedLocalDeckId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .url,
            codingPath: decoder.codingPath
        )
        investigatorName = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .investigatorName,
            codingPath: decoder.codingPath
        )
        lastUpdatedAt = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .lastUpdatedAt,
            codingPath: decoder.codingPath
        )
        version = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .version,
            codingPath: decoder.codingPath
        )
        linkedLocalDeckId = try decodeRequiredNullable(
            DeckID.self,
            from: container,
            forKey: .linkedLocalDeckId,
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(investigatorName, forKey: .investigatorName)
        try container.encode(lastUpdatedAt, forKey: .lastUpdatedAt)
        try container.encode(version, forKey: .version)
        try container.encode(linkedLocalDeckId, forKey: .linkedLocalDeckId)
    }
}
