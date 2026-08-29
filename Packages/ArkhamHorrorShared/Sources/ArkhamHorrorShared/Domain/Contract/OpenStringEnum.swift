/// A phantom-tagged, forward-compatible wire enum.
///
/// Known cases are exposed as `static let` constants on each concrete alias (see
/// ``ClassSymbol``, ``Difficulty``, and friends). Unrecognized strings decode and encode
/// losslessly instead of failing, generalizing the hand-written precedent in
/// ``ContractStatus`` to the many similarly-shaped additive string enums introduced by the
/// catalog, deck, and game-lifecycle contracts.
struct OpenStringEnum<Tag: Sendable>: Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension OpenStringEnum: Equatable, Hashable {}

extension OpenStringEnum: Codable {
    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension OpenStringEnum: CustomStringConvertible {
    var description: String {
        rawValue
    }
}
