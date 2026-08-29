@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("JSONValue")
struct JSONValueTests {
    // MARK: - JSONNumber losslessness

    @Test("A whole number within Int64 range round-trips as .integer")
    func integerRoundTrip() throws {
        let data = Data("42".utf8)
        let decoded = try JSONDecoder().decode(JSONNumber.self, from: data)
        #expect(decoded == .integer(42))
        let reencoded = try JSONEncoder().encode(decoded)
        #expect(String(data: reencoded, encoding: .utf8) == "42")
    }

    @Test("A number exceeding Double's 53-bit mantissa decodes losslessly as .integer")
    func largeIntegerLosslessness() throws {
        // 2^53 + 1: the smallest integer Double cannot represent exactly.
        let data = Data("9007199254740993".utf8)
        let decoded = try JSONDecoder().decode(JSONNumber.self, from: data)
        #expect(decoded == .integer(9_007_199_254_740_993))
    }

    @Test("A fractional number decodes as .decimal without Double rounding")
    func decimalRoundTrip() throws {
        let data = Data("4242.5".utf8)
        let decoded = try JSONDecoder().decode(JSONNumber.self, from: data)
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
}
