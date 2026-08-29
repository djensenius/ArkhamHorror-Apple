import Foundation

/// A JSON number decoded and encoded without `Double` precision loss.
///
/// Backend identifiers and numeric literals may exceed `Double`'s 53-bit mantissa (for
/// example ArkhamDB deck IDs). Whole numbers are captured as `Int64`; anything else
/// (fractional, or too large for `Int64`) is captured as `Decimal`, which Foundation's
/// `JSONDecoder` parses directly from the original digit sequence rather than through a
/// lossy `Double` conversion.
enum JSONNumber: Sendable {
    case integer(Int64)
    case decimal(Decimal)
}

extension JSONNumber: Equatable, Hashable {}

extension JSONNumber: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int64.self) {
            self = .integer(intValue)
        } else {
            self = try .decimal(container.decode(Decimal.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value):
            try container.encode(value)
        case let .decimal(value):
            try container.encode(value)
        }
    }
}

extension JSONNumber: CustomStringConvertible {
    var description: String {
        switch self {
        case let .integer(value): String(value)
        case let .decimal(value): "\(value)"
        }
    }
}

/// A recursive JSON value used for schema fields the contract intentionally leaves
/// unconstrained (for example `CardDef.criteria` or `CardDef.customizations`).
///
/// Never uses `Any`: every case is a concrete, `Equatable`/`Sendable`/`Codable` payload, so
/// unconstrained fields can still be compared, transferred across concurrency domains, and
/// round-tripped exactly rather than silently erased.
indirect enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Equatable, Hashable {}

extension JSONValue: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(JSONNumber.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}
