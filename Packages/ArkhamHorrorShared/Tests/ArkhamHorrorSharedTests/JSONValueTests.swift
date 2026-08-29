@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("JSONValue")
struct JSONValueTests {
    // MARK: - JSONNumber losslessness

    @Test("A whole number within Int64 range round-trips as .integer")
    func integerRoundTrip() throws {
        let data = Data("42".utf8)
        let decoded = try ContractJSON.decode(JSONNumber.self, from: data)
        #expect(decoded == .integer(42))
        let reencoded = try ContractJSON.encode(decoded)
        #expect(String(data: reencoded, encoding: .utf8) == "42")
    }

    @Test("A number exceeding Double's 53-bit mantissa decodes losslessly as .integer")
    func largeIntegerLosslessness() throws {
        // 2^53 + 1: the smallest integer Double cannot represent exactly.
        let data = Data("9007199254740993".utf8)
        let decoded = try ContractJSON.decode(JSONNumber.self, from: data)
        #expect(decoded == .integer(9_007_199_254_740_993))
    }

    @Test("A fractional number decodes as .decimal without Double rounding")
    func decimalRoundTrip() throws {
        let data = Data("4242.5".utf8)
        let decoded = try ContractJSON.decode(JSONNumber.self, from: data)
        #expect(try decoded == .decimal(#require(Decimal(string: "4242.5"))))
    }

    // MARK: - JSONValue variants

    @Test("Every JSON value kind decodes to its matching JSONValue case")
    func decodesAllVariants() throws {
        let json = """
        {"n": null, "b": true, "i": 7, "s": "hi", "a": [1, "x"], "o": {"k": 1}}
        """
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
        #expect(fields["n"] == .null)
        #expect(fields["b"] == .bool(true))
        #expect(fields["i"] == .number(.integer(7)))
        #expect(fields["s"] == .string("hi"))
        #expect(fields["a"] == .array([.number(.integer(1)), .string("x")]))
        #expect(fields["o"] == .object(["k": .number(.integer(1))]))
    }

    @Test("Encoding round-trips through decoding for a nested structure")
    func encodeDecodeRoundTrip() throws {
        let value = JSONValue.object([
            "list": .array([.number(.integer(1)), .null, .bool(false)]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    // MARK: - Round 6 MEDIUM #3: typeMismatch descriptions must stay O(1), never recursive

    @Test("typeMismatch's description stays short regardless of a wide array's element count")
    func typeMismatchDescriptionIsBoundedForWideArray() {
        // `JSONValue` deliberately has no `CustomStringConvertible`, so interpolating it
        // directly (the pre-fix behavior) fell through to Swift's default enum-mirror
        // description, which recursively stringifies every element. `kindDescription`
        // reports only the node's own kind and immediate element count -- never recursing
        // -- so the description must stay short no matter how many elements the array has.
        let wideArray = JSONValue.array(
            Array(repeating: JSONValue.number(.integer(1)), count: 100_000)
        )
        let error = LosslessJSONPrimitive.typeMismatch(Bool.self, wideArray, [])
        guard case let .typeMismatch(_, context) = error else {
            Issue.record("Expected a typeMismatch error")
            return
        }
        #expect(context.debugDescription.count < 200)
        #expect(context.debugDescription.contains("array(100000 elements)"))
    }

    @Test("typeMismatch's description stays short regardless of nesting depth")
    func typeMismatchDescriptionIsBoundedForDeepNesting() {
        // Reproduces the reviewer's specific multiplicative-blowup shape: every nesting
        // level wraps the next in a single-element array/object, so a naive recursive
        // description grows with total node count, not just immediate breadth.
        var deeplyNested = JSONValue.number(.integer(1))
        for _ in 0 ..< 500 {
            deeplyNested = .array([deeplyNested])
        }
        let error = LosslessJSONPrimitive.typeMismatch(Bool.self, deeplyNested, [])
        guard case let .typeMismatch(_, context) = error else {
            Issue.record("Expected a typeMismatch error")
            return
        }
        #expect(context.debugDescription.count < 200)
        #expect(context.debugDescription.contains("array(1 elements)"))
    }

    @Test("A wide/deeply nested document decodes and round-trips through ContractJSON")
    func wideNestedDocumentRoundTripsThroughContractJSON() throws {
        // Proves the O(1) `kindDescription` error-path fix did not regress actual
        // decode/encode correctness on the *success* path for legitimate nested/wide
        // documents -- only the error description's content changed.
        let elements = (0 ..< 5000).map(String.init).joined(separator: ",")
        let json = "{\"list\": [\(elements)], \"nested\": {\"a\": {\"b\": {\"c\": [1, 2, 3]}}}}"
        let decoded = try ContractJSON.decode(JSONValue.self, from: Data(json.utf8))
        guard case let .object(fields) = decoded else {
            Issue.record("Expected an object")
            return
        }
        guard case let .array(list)? = fields["list"] else {
            Issue.record("Expected list to be an array")
            return
        }
        #expect(list.count == 5000)
        #expect(list.first == .number(.integer(0)))
        #expect(list.last == .number(.integer(4999)))
        #expect(fields["nested"] == .object([
            "a": .object(["b": .object(["c": .array([
                .number(.integer(1)), .number(.integer(2)), .number(.integer(3)),
            ])])]),
        ]))
        let reencoded = try ContractJSON.encode(decoded)
        let redecoded = try ContractJSON.decode(JSONValue.self, from: reencoded)
        #expect(redecoded == decoded)
    }
}
