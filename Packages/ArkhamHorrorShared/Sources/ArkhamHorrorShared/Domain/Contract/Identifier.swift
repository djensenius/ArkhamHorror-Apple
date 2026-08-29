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

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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
