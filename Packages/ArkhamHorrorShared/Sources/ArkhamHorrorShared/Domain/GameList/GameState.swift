/// A game's lifecycle state, as reported by `GameListEntry.gameState`.
enum GameState: Sendable {
    /// Waiting for every seat to be claimed; contents are the players who have joined.
    case pending([PlayerID])
    /// Every seat is claimed; waiting for the listed players to choose a deck.
    case chooseDecks([PlayerID])
    /// The game is in progress.
    case active
    /// The game has ended.
    case over
    /// A tag not recognized by this client build.
    case unknown(tag: String, contents: JSONValue?)
}

extension GameState: Equatable, Hashable {}

extension GameState: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "IsPending":
            self = try .pending(container.decode([PlayerID].self, forKey: .contents))
        case "IsChooseDecks":
            self = try .chooseDecks(container.decode([PlayerID].self, forKey: .contents))
        case "IsActive":
            self = .active
        case "IsOver":
            self = .over
        default:
            let contents = try container.decodeIfPresent(JSONValue.self, forKey: .contents)
            self = .unknown(tag: tag, contents: contents)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pending(players):
            try container.encode("IsPending", forKey: .tag)
            try container.encode(players, forKey: .contents)
        case let .chooseDecks(players):
            try container.encode("IsChooseDecks", forKey: .tag)
            try container.encode(players, forKey: .contents)
        case .active:
            try container.encode("IsActive", forKey: .tag)
        case .over:
            try container.encode("IsOver", forKey: .tag)
        case let .unknown(tag, contents):
            try container.encode(tag, forKey: .tag)
            try container.encodeIfPresent(contents, forKey: .contents)
        }
    }
}
