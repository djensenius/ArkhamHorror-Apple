import Foundation

/// Thrown by ``LosslessJSONSerializer`` for the one failure mode a well-formed
/// ``JSONValue`` tree can still exhibit: excessive nesting depth. Every other error this
/// module raises happens at parse or decode time; a `JSONValue` that already exists in
/// memory is otherwise always serializable.
enum LosslessJSONSerializerError: Error, Equatable, Sendable {
    case nestingTooDeep
}

enum LosslessJSONSerializer {
    /// Serializes `value` to canonical (sorted-object-key) JSON bytes.
    ///
    /// Throws ``LosslessJSONSerializerError/nestingTooDeep`` rather than recursing without
    /// bound: `value` may not have come from ``LosslessJSONParser`` (which already enforces
    /// the identical ``LosslessJSONByteScanner/maxNestingDepth`` limit while parsing) —
    /// it may equally be a `JSONValue` built up programmatically or by round-tripping
    /// through this module's `Encoder`/decoder containers, and either path must reject the
    /// same excessive depth before this recursive writer would otherwise exhaust the call
    /// stack.
    static func serialize(_ value: JSONValue) throws -> Data {
        var output: [UInt8] = []
        try write(value, into: &output, depth: 0)
        return Data(output)
    }

    private static func write(_ value: JSONValue, into output: inout [UInt8], depth: Int) throws {
        switch value {
        case .null:
            output.append(contentsOf: "null".utf8)
        case let .bool(bool):
            output.append(contentsOf: (bool ? "true" : "false").utf8)
        case let .number(number):
            output.append(contentsOf: number.description.utf8)
        case let .string(string):
            writeString(string, into: &output)
        case let .array(elements):
            let nextDepth = try enteredDepth(depth)
            output.append(0x5B)
            for (index, element) in elements.enumerated() {
                if index > 0 {
                    output.append(0x2C)
                }
                try write(element, into: &output, depth: nextDepth)
            }
            output.append(0x5D)
        case let .object(dictionary):
            let nextDepth = try enteredDepth(depth)
            output.append(0x7B)
            for (index, key) in dictionary.keys.sorted().enumerated() {
                if index > 0 {
                    output.append(0x2C)
                }
                writeString(key, into: &output)
                output.append(0x3A)
                try write(dictionary[key] ?? .null, into: &output, depth: nextDepth)
            }
            output.append(0x7D)
        }
    }

    /// `depth + 1`, throwing once it would exceed ``LosslessJSONByteScanner/maxNestingDepth``
    /// — the same conservative ceiling the parser enforces, so a document this module could
    /// parse is exactly the set of documents it can also serialize (and vice versa).
    private static func enteredDepth(_ depth: Int) throws -> Int {
        let nextDepth = depth + 1
        guard nextDepth <= LosslessJSONByteScanner.maxNestingDepth else {
            throw LosslessJSONSerializerError.nestingTooDeep
        }
        return nextDepth
    }

    private static func writeString(_ string: String, into output: inout [UInt8]) {
        output.append(0x22)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output.append(contentsOf: "\\\"".utf8)
            case "\\": output.append(contentsOf: "\\\\".utf8)
            case "\n": output.append(contentsOf: "\\n".utf8)
            case "\r": output.append(contentsOf: "\\r".utf8)
            case "\t": output.append(contentsOf: "\\t".utf8)
            default:
                if scalar.value < 0x20 {
                    output.append(contentsOf: String(format: "\\u%04x", scalar.value).utf8)
                } else {
                    output.append(contentsOf: String(scalar).utf8)
                }
            }
        }
        output.append(0x22)
    }
}

/// The canonical, lossless decode/encode path for contract JSON payloads (catalog, deck,
/// and game-lifecycle/list data). Unlike a standard `JSONDecoder`/`JSONEncoder`, this path
/// never rounds or rejects a JSON number: every ``JSONNumber``/``JSONValue`` field decoded
/// or encoded through it retains its exact original precision, and ``rawToken``-bearing
/// numbers re-encode byte-for-byte. A network client consuming these contract endpoints
/// should decode/encode exclusively through this type, not through
/// `JSONDecoder`/`JSONEncoder` directly.
///
/// `decode` is this module's designated boundary for untrusted/remote bytes: it enforces
/// ``LosslessJSONParser/defaultMaxDocumentByteCount`` before any scanning begins (see that
/// property's documentation). `encode`, by contrast, only ever serializes a `JSONValue`
/// tree already built from validated, in-process Swift values (an already-decoded/
/// programmatically-constructed `Encodable`, whose own nesting is already bounded by
/// ``LosslessJSONSerializer``'s depth check) — it has no separate raw-byte input to bound,
/// so no additional output-size cap is imposed here. A future network layer sending
/// `encode`'s output over the wire remains responsible for whatever transport-level size
/// policy it needs; this type's contract is only ever "faithfully serialize a value that
/// already exists in memory", not "bound the size of arbitrary attacker-supplied bytes".
enum ContractJSON {
    static func decode<T: Decodable>(
        _: T.Type,
        from data: Data,
        maxByteCount: Int = LosslessJSONParser.defaultMaxDocumentByteCount
    ) throws -> T {
        let value = try LosslessJSONParser.parse(data, maxByteCount: maxByteCount)
        let decoder = LosslessJSONValueDecoder(value: value, codingPath: [])
        return try T(from: decoder)
    }

    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = LosslessJSONValueEncoder(codingPath: [])
        try value.encode(to: encoder)
        return try LosslessJSONSerializer.serialize(encoder.encodedValue)
    }
}
