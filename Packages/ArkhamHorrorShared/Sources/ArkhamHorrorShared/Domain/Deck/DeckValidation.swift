/// A single deck validation error. Currently only `UnimplementedCard` is documented by the
/// schema (its `tag` is a `const`); any other tag decodes as ``unsupported(rawObject:)``
/// instead of failing, preserving forward compatibility while never being conflated with
/// ``unimplementedCard(_:)`` or resubmitted as if understood.
enum DeckValidationError: Sendable {
    /// The deck references a card this server build cannot yet play.
    case unimplementedCard(CardCode)
    /// A tag not recognized by this client build. Preserves the complete raw wire object
    /// (tag, and contents presence/absence/null-ness, plus any additive keys) so nothing
    /// is lost; never encodable, since resubmitting data this client doesn't understand
    /// is unsafe by construction.
    case unsupported(rawObject: JSONValue)
}

extension DeckValidationError: Equatable, Hashable {}

/// Thrown when encoding a ``DeckValidationError`` this client build never recognized.
enum DeckValidationErrorError: Error, Equatable, Sendable {
    case cannotEncodeUnsupportedTag
}

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
            self = try .unsupported(rawObject: JSONValue(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .unimplementedCard(cardCode):
            try container.encode("UnimplementedCard", forKey: .tag)
            try container.encode(cardCode, forKey: .contents)
        case .unsupported:
            throw DeckValidationErrorError.cannotEncodeUnsupportedTag
        }
    }
}

/// A non-empty list of deck validation failures, matching the wire contract's guarantee of
/// at least one entry whenever this shape (rather than ``DeckValidationSuccess``'s empty
/// array) is returned. Distinguishing this from a bare `[DeckValidationError]` means an
/// empty array cannot be mistaken for a well-formed (if vacuous) failure list; the client's
/// interpretation of "success" vs. "failure" for a given response remains driven by HTTP
/// status, not by guessing between the two array shapes.
typealias DeckValidationErrors = NonEmptyArray<DeckValidationError>

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
