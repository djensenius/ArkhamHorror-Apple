/// The operational status reported by the server capabilities endpoint.
///
/// Forward-compatible: future status strings are preserved as-is rather than
/// failing decoding. Do **not** switch exhaustively without a `default` case that
/// handles forward-compatible extensions.
struct ContractStatus: Equatable, Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    static let baselineIncomplete = ContractStatus("baseline-incomplete")
    static let stable = ContractStatus("stable")
}

extension ContractStatus: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ContractStatus: CustomStringConvertible {
    var description: String {
        rawValue
    }
}
