/// A saved-deck answer for the live ChooseDeck question.
struct DeckAnswer: Sendable, Equatable, Codable {
    let deckId: DeckID
    let playerId: PlayerID

    private enum CodingKeys: String, CodingKey {
        case tag
        case deckId
        case playerId
    }

    init(deckId: DeckID, playerId: PlayerID) {
        self.deckId = deckId
        self.playerId = playerId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        guard tag == "DeckAnswer" else {
            throw DecodingError.dataCorruptedError(
                forKey: .tag,
                in: container,
                debugDescription: "Expected DeckAnswer tag"
            )
        }
        deckId = try container.decode(DeckID.self, forKey: .deckId)
        playerId = try container.decode(PlayerID.self, forKey: .playerId)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("DeckAnswer", forKey: .tag)
        try container.encode(deckId, forKey: .deckId)
        try container.encode(playerId, forKey: .playerId)
    }
}

/// An unsaved deck-list answer for the live ChooseDeck question.
struct DeckListAnswer: Sendable, Equatable, Codable {
    let deckList: DeckListInput
    let playerId: PlayerID

    private enum CodingKeys: String, CodingKey {
        case tag
        case deckList
        case playerId
    }

    init(deckList: DeckListInput, playerId: PlayerID) {
        self.deckList = deckList
        self.playerId = playerId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        guard tag == "DeckListAnswer" else {
            throw DecodingError.dataCorruptedError(
                forKey: .tag,
                in: container,
                debugDescription: "Expected DeckListAnswer tag"
            )
        }
        deckList = try container.decode(DeckListInput.self, forKey: .deckList)
        playerId = try container.decode(PlayerID.self, forKey: .playerId)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("DeckListAnswer", forKey: .tag)
        try container.encode(deckList, forKey: .deckList)
        try container.encode(playerId, forKey: .playerId)
    }
}

enum LiveChooseDeckQuestion {
    static func matches(_ value: JSONValue) -> Bool {
        value == .object(["tag": .string("ChooseDeck")])
            || value.wrapsExactQuestion(tag: "QuestionLabel", innerTag: "ChooseDeck")
    }
}

private extension JSONValue {
    func wrapsExactQuestion(tag expectedTag: String, innerTag expectedInnerTag: String) -> Bool {
        guard case let .object(object) = self,
              object["tag"] == .string(expectedTag),
              object["question"] == .object(["tag": .string(expectedInnerTag)])
        else { return false }
        return true
    }
}
