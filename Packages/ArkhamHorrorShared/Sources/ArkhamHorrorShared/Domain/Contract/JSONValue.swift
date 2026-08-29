import Foundation

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
    /// The same conservative ceiling ``LosslessJSONByteScanner``/``LosslessJSONSerializer``
    /// enforce while parsing/serializing raw bytes, applied here via `codingPath.count` (a
    /// reliable depth proxy: every `Encoder`/`Decoder` this module vends — and Foundation's
    /// own — appends exactly one coding-path entry per nested container level). This closes
    /// the gap those two byte-level guards cannot: a `JSONValue` tree that was never parsed
    /// from text at all, but instead built up (or decoded into `JSONValue` fields)
    /// programmatically to an excessive depth, would otherwise recurse through this very
    /// `init(from:)`/`encode(to:)` implementation without bound.
    private static func checkNestingDepth(_ codingPath: [any CodingKey]) -> Bool {
        codingPath.count <= LosslessJSONByteScanner.maxNestingDepth
    }

    init(from decoder: any Decoder) throws {
        guard Self.checkNestingDepth(decoder.codingPath) else {
            throw try DecodingError.dataCorruptedError(
                in: decoder.singleValueContainer(),
                debugDescription: "JSON nesting exceeds the maximum supported depth"
            )
        }
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
        guard Self.checkNestingDepth(encoder.codingPath) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "JSON nesting exceeds the maximum supported depth"
                )
            )
        }
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
