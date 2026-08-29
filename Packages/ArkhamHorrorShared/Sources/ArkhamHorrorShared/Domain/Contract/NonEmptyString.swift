import Foundation

/// The error thrown when a string fails a contract's `minLength: 1` constraint.
enum NonEmptyStringError: Error, Equatable, Sendable {
    case empty
}

/// A validated non-empty opaque string, used where the contract's schema declares
/// `minLength: 1` but imposes no further structural constraint (unlike ``CardCode``'s `c`
/// prefix pattern). Distinguished at compile time by a phantom `Tag`, so (for example) an
/// investigator identifier and a card artwork identifier cannot be interchanged even though
/// both wrap `String`.
struct NonEmptyString<Tag: Sendable>: Sendable {
    let rawValue: String

    init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw NonEmptyStringError.empty
        }
        self.rawValue = rawValue
    }
}

extension NonEmptyString: Equatable, Hashable {}

extension NonEmptyString: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        do {
            try self.init(raw)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a non-empty string, got an empty string"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension NonEmptyString: CustomStringConvertible {
    var description: String {
        rawValue
    }
}

/// Phantom tag distinguishing ``InvestigatorCode``.
enum InvestigatorCodeTag: Sendable {}
/// A nonempty, opaque investigator identifier: `ChooseDeckRequest.investigatorId`,
/// `ClaimSeatRequest.investigatorId`, and `DeckListInput.investigatorCode` all use this
/// shape. Unlike ``CardCode``, no `c` prefix is required — the contract shows this value
/// both with (`c01001`) and without (`01001`) the prefix depending on context.
typealias InvestigatorCode = NonEmptyString<InvestigatorCodeTag>

/// Phantom tag distinguishing ``ArtworkIdentifier``.
enum ArtworkIdentifierTag: Sendable {}
/// A nonempty artwork identifier: `CardDef.art` and each element of `InvestigatorArtwork`.
typealias ArtworkIdentifier = NonEmptyString<ArtworkIdentifierTag>
