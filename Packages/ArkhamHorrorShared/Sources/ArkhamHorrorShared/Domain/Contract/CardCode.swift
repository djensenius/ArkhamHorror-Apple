/// The error thrown when a string does not conform to the backend's Aeson-prefixed card
/// code format.
enum CardCodeError: Error, Equatable, Sendable {
    /// The string is empty, or does not start with `c` followed by at least one more
    /// character (for example `c01020` or `c:dark-matter:151`).
    case malformed
}

/// A validated card code: the Aeson `c` prefix followed by a non-empty payload.
///
/// Matches the contract's `^c.+$` pattern. Covers both official codes (`c01020`) and
/// homebrew codes (`c:dark-matter:151`); no further structure is imposed beyond the
/// published pattern.
struct CardCode: Sendable {
    let rawValue: String

    init(_ rawValue: String) throws {
        guard rawValue.first == "c", rawValue.count > 1 else {
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
