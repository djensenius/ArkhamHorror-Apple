/// A saved deck, as returned by the deck endpoints once a ``DeckListInput`` has been
/// normalized and persisted.
struct Deck: Sendable, Equatable {
    let id: DeckID
    let userId: Int
    let url: String?
    let name: String
    let investigatorName: String
    let list: DeckList
    let lastUsedAt: String?
    let overlay: JSONValue?
    let playList: DeckList?

    init(
        id: DeckID,
        userId: Int,
        url: String?,
        name: String,
        investigatorName: String,
        list: DeckList,
        lastUsedAt: String? = nil,
        overlay: JSONValue? = nil,
        playList: DeckList? = nil
    ) {
        self.id = id
        self.userId = userId
        self.url = url
        self.name = name
        self.investigatorName = investigatorName
        self.list = list
        self.lastUsedAt = lastUsedAt
        self.overlay = overlay
        self.playList = playList
    }

    var playableList: DeckList {
        playList ?? list
    }
}

extension Deck: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case userId
        case url
        case name
        case investigatorName
        case list
        case lastUsedAt
        case overlay
        case playList
    }

    /// `url` is required by the schema (`required: [..., url, ...]`) but nullable: a
    /// missing key is a contract violation, while an explicit `null` is the normal way a
    /// deck without an ArkhamDB URL is represented.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(DeckID.self, forKey: .id)
        userId = try container.decode(Int.self, forKey: .userId)
        url = try decodeRequiredNullable(
            String.self,
            from: container,
            forKey: .url,
            codingPath: decoder.codingPath
        )
        name = try container.decode(String.self, forKey: .name)
        investigatorName = try container.decode(String.self, forKey: .investigatorName)
        list = try container.decode(DeckList.self, forKey: .list)
        lastUsedAt = try container.decodeIfPresent(String.self, forKey: .lastUsedAt)
        overlay = try container.decodeIfPresent(JSONValue.self, forKey: .overlay)
        playList = try container.decodeIfPresent(DeckList.self, forKey: .playList)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userId, forKey: .userId)
        // Non-`IfPresent` encode so `nil` produces an explicit `null` rather than omitting
        // the key, matching the always-present wire shape.
        try container.encode(url, forKey: .url)
        try container.encode(name, forKey: .name)
        try container.encode(investigatorName, forKey: .investigatorName)
        try container.encode(list, forKey: .list)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(overlay, forKey: .overlay)
        try container.encodeIfPresent(playList, forKey: .playList)
    }
}

/// A list of saved decks.
typealias DeckListResponse = [Deck]
