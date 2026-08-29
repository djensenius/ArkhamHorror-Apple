/// A Token-keyed multiset entry (for example clue/doom/resource counts), encoded on the
/// wire as a 2-element `[tokenName, count]` array. Shared by `Act.tokens`,
/// `Agenda.tokens`, `Location.tokens`, and `Investigator.tokens` — every one of the four
/// backend fields matching this exact shape.
///
/// `token` is an open string set (the closed `Arkham.Token.Token` type still gains new
/// cases across expansions), so it decodes as a plain `String` rather than a closed enum.
struct TokenCount: Sendable {
    let token: String
    let count: Int
}

extension TokenCount: Equatable, Hashable {}

extension TokenCount: Codable {
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        token = try container.decode(String.self)
        count = try container.decode(Int.self)
        guard (0 ... Int.max).contains(count) else {
            let context = DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Expected a non-negative token count, got \(count)"
            )
            throw DecodingError.dataCorrupted(context)
        }
        guard container.isAtEnd else {
            let context = DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Expected exactly 2 elements for TokenCount"
            )
            throw DecodingError.dataCorrupted(context)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(token)
        try container.encode(count)
    }
}
