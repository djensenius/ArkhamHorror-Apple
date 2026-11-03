/// The account-link status; ArkhamDB tokens stay on the server.
struct ArkhamDBLinkStatus: Sendable, Equatable {
    let linked: Bool
    let remoteAccountId: String?
    let remoteAccountName: String?
    let tokenExpiry: String?
    let linkedAt: String?
    let writeBackEnabledDeckCount: Int
    /// Per-deck write-back rows (schema 0.1.55+). A 0.1.54 server omits the key, which
    /// decodes as empty. Like the remote deck list, one unreadable row is skipped and
    /// counted rather than hiding the whole account panel (including unlink).
    let deckLinks: [ArkhamDBWriteBackStatus]
    let skippedDeckLinkCount: Int
}

extension ArkhamDBLinkStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case linked
        case remoteAccountId
        case remoteAccountName
        case tokenExpiry
        case linkedAt
        case writeBackEnabledDeckCount
        case deckLinks
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        linked = try container.decode(Bool.self, forKey: .linked)
        remoteAccountId = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .remoteAccountId,
            codingPath: decoder.codingPath
        )
        remoteAccountName = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .remoteAccountName,
            codingPath: decoder.codingPath
        )
        tokenExpiry = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .tokenExpiry,
            codingPath: decoder.codingPath
        )
        linkedAt = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .linkedAt,
            codingPath: decoder.codingPath
        )
        writeBackEnabledDeckCount = try container.decode(
            Int.self,
            forKey: .writeBackEnabledDeckCount
        )
        guard writeBackEnabledDeckCount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .writeBackEnabledDeckCount,
                in: container,
                debugDescription: "writeBackEnabledDeckCount must be non-negative"
            )
        }
        // Missing is 0.1.54 compatibility; an explicit null or non-array still throws.
        let rows = try container.contains(.deckLinks)
            ? container.decode([JSONValue].self, forKey: .deckLinks)
            : []
        deckLinks = rows.compactMap { row in
            guard let data = try? ContractJSON.encode(row) else { return nil }
            return try? ContractJSON.decode(ArkhamDBWriteBackStatus.self, from: data)
        }
        skippedDeckLinkCount = rows.count - deckLinks.count
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(linked, forKey: .linked)
        try container.encode(remoteAccountId, forKey: .remoteAccountId)
        try container.encode(remoteAccountName, forKey: .remoteAccountName)
        try container.encode(tokenExpiry, forKey: .tokenExpiry)
        try container.encode(linkedAt, forKey: .linkedAt)
        try container.encode(writeBackEnabledDeckCount, forKey: .writeBackEnabledDeckCount)
        // Omitted when empty so a 0.1.54 status round-trips unchanged. The 0.1.55 repin
        // (fixture `deckLinks: []`) should switch this to always encode the key.
        if !deckLinks.isEmpty {
            try container.encode(deckLinks, forKey: .deckLinks)
        }
    }
}
