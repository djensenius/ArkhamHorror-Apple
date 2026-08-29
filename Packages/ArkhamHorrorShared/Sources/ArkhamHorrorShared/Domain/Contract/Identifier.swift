import Foundation

/// A UUID-backed identifier distinguished at compile time by a phantom `Tag`, so a
/// ``GameID`` and a ``DeckID`` cannot be interchanged even though both wrap `UUID`.
///
/// Decoding delegates to `UUID`'s own `Decodable` conformance, which throws (never force-
/// unwraps) on a malformed UUID string.
struct Identifier<Tag: Sendable>: Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

extension Identifier: Equatable, Hashable {}

extension Identifier: Codable {
    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    /// Encodes as an explicit lowercase-hyphenated string, matching the backend's own
    /// canonical UUID rendering (and this type's ``CodingKeyRepresentable`` map-key
    /// encoding in `BoardIdentifiers.swift`) exactly. Delegating to `UUID`'s own
    /// `Encodable` conformance (`container.encode(rawValue)`) would instead emit
    /// Foundation's uppercase `uuidString` — silently diverging from the wire's actual
    /// casing for any UUID containing a hex letter, and from this same type's own
    /// map-key form, even though both positions represent the identical value.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }
}

extension Identifier: CustomStringConvertible {
    var description: String {
        rawValue.uuidString
    }
}

/// Phantom tag distinguishing ``GameID``.
enum GameIDTag: Sendable {}
/// A game's UUID identifier.
typealias GameID = Identifier<GameIDTag>

/// Phantom tag distinguishing ``DeckID``.
enum DeckIDTag: Sendable {}
/// A saved deck's UUID identifier.
typealias DeckID = Identifier<DeckIDTag>

/// Phantom tag distinguishing ``PlayerID``.
enum PlayerIDTag: Sendable {}
/// A game participant's UUID identifier, as used by ``GameState``'s deck-choice waits.
typealias PlayerID = Identifier<PlayerIDTag>
