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

extension JSONValue {
    /// A shallow, `O(1)` description of this node's kind (and immediate size for the two
    /// container cases) — deliberately never recurses into `array`/`object` children.
    ///
    /// `JSONValue` intentionally has no `CustomStringConvertible` conformance, so
    /// interpolating a value directly (`"\(value)"`) falls through to Swift's default
    /// enum-mirror description, which — for this `indirect` recursive type — walks and
    /// stringifies the *entire* subtree. Error paths that probe a value's type and fail
    /// (for example every `LosslessJSONPrimitive.typeMismatch` case, and the multiple
    /// failed probes `JSONValue.init(from:)` itself performs while trying each case in
    /// turn) must describe only the node actually inspected, never its descendants:
    /// otherwise each failed probe at each nesting level costs time proportional to the
    /// size of everything still nested beneath it, compounding across a deep/wide tree.
    var kindDescription: String {
        switch self {
        case .null: "null"
        case .bool: "bool"
        case .number: "number"
        case .string: "string"
        case let .array(elements): "array(\(elements.count) elements)"
        case let .object(members): "object(\(members.count) keys)"
        }
    }
}

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
            // `decoder.codingPath` is already available without obtaining (and thus
            // without needing to `try`) a container, so this reports the same coding
            // path `dataCorruptedError(in:debugDescription:)` would have derived from
            // one, without a redundant `try` on a call that cannot itself throw.
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "JSON nesting exceeds the maximum supported depth"
                )
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
