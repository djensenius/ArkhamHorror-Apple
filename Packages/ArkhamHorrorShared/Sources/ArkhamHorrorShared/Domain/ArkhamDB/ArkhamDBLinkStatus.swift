/// The account-link status; ArkhamDB tokens stay on the server.
struct ArkhamDBLinkStatus: Sendable, Equatable {
    let linked: Bool
    let remoteAccountId: String?
    let remoteAccountName: String?
    let tokenExpiry: String?
    let linkedAt: String?
    let writeBackEnabledDeckCount: Int
}

extension ArkhamDBLinkStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case linked
        case remoteAccountId
        case remoteAccountName
        case tokenExpiry
        case linkedAt
        case writeBackEnabledDeckCount
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
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(linked, forKey: .linked)
        try container.encode(remoteAccountId, forKey: .remoteAccountId)
        try container.encode(remoteAccountName, forKey: .remoteAccountName)
        try container.encode(tokenExpiry, forKey: .tokenExpiry)
        try container.encode(linkedAt, forKey: .linkedAt)
        try container.encode(writeBackEnabledDeckCount, forKey: .writeBackEnabledDeckCount)
    }
}
