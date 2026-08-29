/// The error thrown when a string does not conform to the backend's Aeson-prefixed card
/// code format.
enum CardCodeError: Error, Equatable, Sendable {
    /// The string is empty, or does not start with `c` followed by at least one more
    /// character (for example `c01020` or `c:dark-matter:151`).
    case malformed
}

/// A validated card code: the Aeson `c` prefix followed by a non-empty payload.
///
/// Matches the contract's `^c.+$` pattern at Unicode scalar (code point) granularity, not
/// `String`'s grapheme-cluster granularity: a combining mark immediately after `c` (for
/// example `"c\u{0301}"`) is a second Unicode scalar and therefore a valid one-character
/// payload, even though Swift's default grapheme clustering merges it with `c` into a
/// single `Character`. `.` in the published regex is ECMAScript-style — it matches any
/// scalar except the four line terminators (`\n`, `\r`, `U+2028`, `U+2029`) — so a payload
/// containing one of those is rejected. The raw string is stored and compared verbatim;
/// no Unicode normalization is ever applied.
struct CardCode: Sendable {
    let rawValue: String

    /// The four code points ECMAScript's `.` excludes from matching by default.
    private static let lineTerminators: Set<Unicode.Scalar> = [
        "\u{000A}", "\u{000D}", "\u{2028}", "\u{2029}",
    ]

    init(_ rawValue: String) throws {
        let scalars = rawValue.unicodeScalars
        guard scalars.first == "c" else {
            throw CardCodeError.malformed
        }
        let payload = scalars.dropFirst()
        guard !payload.isEmpty, !payload.contains(where: Self.lineTerminators.contains) else {
            throw CardCodeError.malformed
        }
        self.rawValue = rawValue
    }
}

extension CardCode: Equatable, Hashable {}

extension CardCode: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        do {
            try self.init(raw)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid card code '\(raw)': \(error)"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension CardCode: CustomStringConvertible {
    var description: String {
        rawValue
    }
}
