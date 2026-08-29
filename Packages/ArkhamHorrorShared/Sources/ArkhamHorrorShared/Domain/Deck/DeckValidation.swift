/// A single deck validation error. Currently only `UnimplementedCard` is documented; any
/// other tag decodes to `.unknown` instead of failing, preserving forward compatibility.
enum DeckValidationError: Sendable {
    /// The deck references a card this server build cannot yet play.
    case unimplementedCard(CardCode)
    /// A tag not recognized by this client build.
    case unknown(tag: String, contents: JSONValue?)
}

extension DeckValidationError: Equatable, Hashable {}

extension DeckValidationError: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case contents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        switch tag {
        case "UnimplementedCard":
            self = try .unimplementedCard(container.decode(CardCode.self, forKey: .contents))
        default:
            let contents = try container.decodeIfPresent(JSONValue.self, forKey: .contents)
            self = .unknown(tag: tag, contents: contents)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .unimplementedCard(cardCode):
            try container.encode("UnimplementedCard", forKey: .tag)
            try container.encode(cardCode, forKey: .contents)
        case let .unknown(tag, contents):
            try container.encode(tag, forKey: .tag)
            try container.encodeIfPresent(contents, forKey: .contents)
        }
    }
}

/// A non-empty list of deck validation failures.
typealias DeckValidationErrors = [DeckValidationError]

/// The marker returned when deck validation finds no errors: always an empty JSON array.
struct DeckValidationSuccess: Sendable, Equatable, Hashable {}

extension DeckValidationSuccess: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.unkeyedContainer()
        if !container.isAtEnd {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected an empty array for deckValidationSuccess, got a "
                    + "non-empty array"
            )
            throw DecodingError.dataCorrupted(context)
        }
    }

    func encode(to encoder: any Encoder) throws {
        _ = encoder.unkeyedContainer()
    }
}

/// A deck operation (create/fetch/sync) failure with a human-readable message.
struct DeckOperationError: Sendable, Equatable, Codable {
    let errorMsg: String
}
