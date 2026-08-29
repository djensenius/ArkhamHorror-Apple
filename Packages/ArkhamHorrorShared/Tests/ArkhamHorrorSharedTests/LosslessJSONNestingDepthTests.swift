@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Adversarial coverage for the nesting-depth guard (HIGH #2): unbounded recursive descent
/// through the mutually-recursive `parseValue`/`parseObject`/`parseArray` cycle, the
/// recursive serializer, and `JSONValue`'s own recursive `Codable` conformance would each
/// otherwise stack-overflow (a crash, not a catchable error) for a sufficiently deep
/// document. Every guard shares the same `LosslessJSONByteScanner.maxNestingDepth` ceiling,
/// so a document any one of these three paths accepts is exactly the set every other path
/// also accepts. That shared ceiling was itself picked empirically (see the doc comment on
/// `maxNestingDepth`): the "exactly at the limit" tests below are precisely what proved a
/// naive, purely-theoretical limit choice unsafe on a real (if constrained) stack.
@Suite("Lossless JSON nesting depth")
struct LosslessJSONNestingDepthTests {
    private static let limit = LosslessJSONByteScanner.maxNestingDepth

    /// `count`-deep nested JSON arrays around a scalar leaf, e.g. `count == 2` produces
    /// `"[[0]]"`.
    private static func nestedArrayText(depth: Int) -> Data {
        Data(
            (String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)).utf8
        )
    }

    /// `count`-deep nested JSON objects around a scalar leaf, each with a single key `"a"`.
    private static func nestedObjectText(depth: Int) -> Data {
        let opening = String(repeating: "{\"a\":", count: depth)
        let closing = String(repeating: "}", count: depth)
        return Data((opening + "0" + closing).utf8)
    }

    /// A programmatically constructed (never parsed) `JSONValue` tree `depth` arrays deep.
    private static func nestedArrayValue(depth: Int) -> JSONValue {
        var value: JSONValue = .number(.integer(0))
        for _ in 0 ..< depth {
            value = .array([value])
        }
        return value
    }

    // MARK: - Parser: arrays

    @Test("A document nested exactly to the depth limit parses (arrays)")
    func arrayAtLimitParses() throws {
        let value = try LosslessJSONParser.parse(Self.nestedArrayText(depth: Self.limit))
        // Unwrap all the way down to the scalar leaf to confirm the whole tree round-tripped,
        // not just that parsing didn't throw.
        var current = value
        for _ in 0 ..< Self.limit {
            guard case let .array(elements) = current, elements.count == 1 else {
                Issue.record("Expected a single-element array at every level")
                return
            }
            current = elements[0]
        }
        #expect(current == .number(.integer(0)))
    }

    @Test("A document nested one level past the depth limit is rejected (arrays)")
    func arrayOnePastLimitRejected() {
        #expect(throws: LosslessJSONParserError.nestingTooDeep) {
            try LosslessJSONParser.parse(Self.nestedArrayText(depth: Self.limit + 1))
        }
    }

    // MARK: - Parser: objects

    @Test("A document nested exactly to the depth limit parses (objects)")
    func objectAtLimitParses() throws {
        let value = try LosslessJSONParser.parse(Self.nestedObjectText(depth: Self.limit))
        var current = value
        for _ in 0 ..< Self.limit {
            guard case let .object(dictionary) = current, let inner = dictionary["a"] else {
                Issue.record("Expected a single-key object at every level")
                return
            }
            current = inner
        }
        #expect(current == .number(.integer(0)))
    }

    @Test("A document nested one level past the depth limit is rejected (objects)")
    func objectOnePastLimitRejected() {
        #expect(throws: LosslessJSONParserError.nestingTooDeep) {
            try LosslessJSONParser.parse(Self.nestedObjectText(depth: Self.limit + 1))
        }
    }

    // MARK: - Parser: mixed array/object nesting

    @Test("A document nested one level past the depth limit is rejected (mixed array/object)")
    func mixedOnePastLimitRejected() {
        var text = ""
        for index in 0 ..< (Self.limit + 1) {
            text += index.isMultiple(of: 2) ? "[" : "{\"a\":"
        }
        text += "0"
        for index in stride(from: Self.limit, through: 0, by: -1) {
            text += index.isMultiple(of: 2) ? "]" : "}"
        }
        #expect(throws: LosslessJSONParserError.nestingTooDeep) {
            try LosslessJSONParser.parse(Data(text.utf8))
        }
    }

    // MARK: - A very deep document fails cleanly rather than crashing

    @Test("A 50,000-deep document returns a typed error, never crashes")
    func veryDeepDocumentReturnsTypedError() {
        // Enormously deeper than the limit: proves the parser fails fast (long before
        // descending anywhere near a real stack limit) rather than merely failing right at
        // the boundary.
        #expect(throws: LosslessJSONParserError.nestingTooDeep) {
            try LosslessJSONParser.parse(Self.nestedArrayText(depth: 50000))
        }
    }

    // MARK: - Serializer

    @Test("A JSONValue tree exactly at the depth limit serializes")
    func serializeAtLimitSucceeds() throws {
        let value = Self.nestedArrayValue(depth: Self.limit)
        let data = try LosslessJSONSerializer.serialize(value)
        #expect(!data.isEmpty)
        // Round-trips back through the parser (which enforces the identical limit) too.
        let reparsed = try LosslessJSONParser.parse(data)
        #expect(reparsed == value)
    }

    @Test("A JSONValue tree one level past the depth limit is rejected by the serializer")
    func serializeOnePastLimitRejected() {
        let value = Self.nestedArrayValue(depth: Self.limit + 1)
        #expect(throws: LosslessJSONSerializerError.nestingTooDeep) {
            try LosslessJSONSerializer.serialize(value)
        }
    }

    // MARK: - JSONValue's own Codable conformance (programmatic trees, never parsed)

    //
    // Closes the gap the byte-level parser/serializer guards above cannot: a `JSONValue`
    // tree that was built up programmatically (never round-tripped through raw bytes) can
    // still recurse through `JSONValue.init(from:)`/`encode(to:)` without bound unless those
    // themselves also enforce the same ceiling via `codingPath.count`.

    @Test("Encoding a programmatic JSONValue tree exactly at the depth limit succeeds")
    func encodeProgrammaticTreeAtLimitSucceeds() throws {
        let value = Self.nestedArrayValue(depth: Self.limit)
        let data = try ContractJSON.encode(value)
        #expect(!data.isEmpty)
    }

    @Test("Encoding a programmatic JSONValue tree one level past the depth limit throws")
    func encodeProgrammaticTreeOnePastLimitThrows() {
        let value = Self.nestedArrayValue(depth: Self.limit + 1)
        #expect(throws: (any Error).self) {
            try ContractJSON.encode(value)
        }
    }

    @Test("Decoding a programmatic JSONValue tree exactly at the depth limit succeeds")
    func decodeProgrammaticTreeAtLimitSucceeds() throws {
        let bytes = Self.nestedArrayText(depth: Self.limit)
        let decoded = try ContractJSON.decode(JSONValue.self, from: bytes)
        #expect(decoded == Self.nestedArrayValue(depth: Self.limit))
    }
}
