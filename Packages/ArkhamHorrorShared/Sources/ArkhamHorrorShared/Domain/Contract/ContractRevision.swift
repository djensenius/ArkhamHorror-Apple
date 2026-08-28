/// Errors produced when parsing a ``ContractRevision`` from a string.
enum ContractRevisionError: Error, Equatable, Sendable {
    /// The string does not conform to strictly `major.minor.patch` with ASCII decimal digits.
    ///
    /// Covers: wrong field count, empty components, non-digit characters (including `-`, `+`,
    /// whitespace, and Unicode decimal digits), and integer overflow.
    case malformed
}

/// A strict numeric three-component revision (major.minor.patch).
///
/// Comparison is always numeric, never lexical: `0.1.9 < 0.1.11`.
struct ContractRevision: Sendable {
    let major: Int
    let minor: Int
    let patch: Int
}

extension ContractRevision: Equatable, Hashable {}

extension ContractRevision: Comparable {
    static func < (lhs: ContractRevision, rhs: ContractRevision) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }
}

extension ContractRevision: CustomStringConvertible {
    var description: String {
        "\(major).\(minor).\(patch)"
    }
}

extension ContractRevision {
    /// Parses a `"major.minor.patch"` string.
    ///
    /// Requires exactly three non-empty components of strictly ASCII decimal digits (`0`–`9`).
    /// Rejects leading `+` or `-`, whitespace, Unicode decimal digits (e.g. Arabic-Indic),
    /// and values that overflow `Int`. Throws ``ContractRevisionError/malformed`` for all
    /// invalid inputs.
    init(_ string: String) throws {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        // Each component must be non-empty and contain only ASCII decimal digits.
        // This explicitly rejects +/-, whitespace, Unicode digits, and empty strings.
        let isStrictDecimal: (Substring) -> Bool = { component in
            !component.isEmpty
                && component.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
        }
        guard parts.count == 3,
              parts.allSatisfy(isStrictDecimal),
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2])
        else {
            throw ContractRevisionError.malformed
        }
        self.init(major: major, minor: minor, patch: patch)
    }

    /// Constructs a revision from known-valid non-negative literal components.
    ///
    /// Uses `UInt` parameters so negative values are rejected at the call site without
    /// a force-unwrap. Intended for compile-time constants in ``ContractPin`` and tests.
    static func literal(major: UInt, minor: UInt, patch: UInt) -> ContractRevision {
        ContractRevision(major: Int(major), minor: Int(minor), patch: Int(patch))
    }
}

extension ContractRevision: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        do {
            try self.init(string)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid contract revision '\(string)': \(error)"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
