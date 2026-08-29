@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Mutation-resistant coverage for `JSONNumber`'s arbitrary-precision representation and
/// for `ContractJSON`, the parser-bound decode/encode path that actually retains it.
/// Complements ``JSONValueTests`` (which covers `JSONValue`'s recursive shape) and
/// ``LosslessJSONParserTests`` (which covers the byte-level parser's own rejection
/// policy).
@Suite("JSONNumber losslessness")
struct LosslessJSONNumberTests {
    // MARK: - The two triggers cited by the review

    @Test("A 39-fractional-digit literal round-trips exactly through ContractJSON")
    func longFractionalLiteralIsLossless() throws {
        let literal = "1.000000000000000000000000000000000000001"
        let decoded = try ContractJSON.decode(JSONNumber.self, from: Data(literal.utf8))
        #expect(decoded.rawToken == literal)
        #expect(decoded.coefficient == "1000000000000000000000000000000000000001")
        #expect(decoded.exponent == -39)
        let reencoded = try ContractJSON.encode(decoded)
        #expect(String(data: reencoded, encoding: .utf8) == literal)
    }

    @Test("The same 39-fractional-digit literal rounds to 1 through a stock JSONDecoder")
    func longFractionalLiteralIsLossyThroughStockDecoder() throws {
        // This is the control test: it proves the fallback path in `JSONNumber`'s
        // standard `Decodable` conformance (reached only when *not* decoding through
        // `ContractJSON`) really is lossy, so nothing has silently reintroduced the
        // rounding `ContractJSON.decode` exists to avoid.
        let literal = "1.000000000000000000000000000000000000001"
        let decoded = try JSONDecoder().decode(JSONNumber.self, from: Data(literal.utf8))
        #expect(decoded == .integer(1))
        #expect(decoded.rawToken == nil)
    }

    @Test("1e128 round-trips exactly through ContractJSON")
    func hugePositiveExponentIsLossless() throws {
        let decoded = try ContractJSON.decode(JSONNumber.self, from: Data("1e128".utf8))
        #expect(decoded.rawToken == "1e128")
        #expect(decoded.coefficient == "1")
        #expect(decoded.exponent == 128)
        #expect(decoded.plainDecimalString == "1" + String(repeating: "0", count: 128))
        let reencoded = try ContractJSON.encode(decoded)
        #expect(String(data: reencoded, encoding: .utf8) == "1e128")
    }

    @Test("1e128 cannot be represented by the stock JSONDecoder fallback path")
    func hugePositiveExponentRejectedByStockDecoder() throws {
        // `Decimal`'s exponent cannot hold 128, and the value is not an `Int64`, so the
        // fallback path in `JSONNumber.init(from:)` has no representation left to try.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(JSONNumber.self, from: Data("1e128".utf8))
        }
    }

    // MARK: - Exponent/coefficient edge cases

    @Test("A large negative exponent round-trips exactly")
    func hugeNegativeExponentIsLossless() throws {
        let decoded = try ContractJSON.decode(JSONNumber.self, from: Data("5e-128".utf8))
        #expect(decoded.coefficient == "5")
        #expect(decoded.exponent == -128)
        #expect(decoded.rawToken == "5e-128")
        let reencoded = try ContractJSON.encode(decoded)
        #expect(String(data: reencoded, encoding: .utf8) == "5e-128")
    }

    @Test("A 60-digit integer coefficient round-trips exactly")
    func longCoefficientIsLossless() throws {
        let literal = String(repeating: "9", count: 60)
        let decoded = try ContractJSON.decode(JSONNumber.self, from: Data(literal.utf8))
        #expect(decoded.coefficient == literal)
        #expect(decoded.exponent == 0)
        let reencoded = try ContractJSON.encode(decoded)
        #expect(String(data: reencoded, encoding: .utf8) == literal)
    }

    @Test("An integer far beyond UInt64.max round-trips exactly")
    func integerBeyondUInt64IsLossless() throws {
        // UInt64.max is 18446744073709551615 (20 digits); this is 30 digits.
        let literal = "123456789012345678901234567890"
        let decoded = try ContractJSON.decode(JSONNumber.self, from: Data(literal.utf8))
        #expect(decoded.coefficient == literal)
        #expect(decoded.wholeNumberMagnitude == literal)
        let reencoded = try ContractJSON.encode(decoded)
        #expect(String(data: reencoded, encoding: .utf8) == literal)
    }

    @Test("-0 is accepted, preserves its sign in the raw token, and re-encodes as -0")
    func negativeZeroRoundTrips() throws {
        let decoded = try ContractJSON.decode(JSONNumber.self, from: Data("-0".utf8))
        #expect(decoded.sign == .minus)
        #expect(decoded.coefficient == "0")
        #expect(decoded.rawToken == "-0")
        let reencoded = try ContractJSON.encode(decoded)
        #expect(String(data: reencoded, encoding: .utf8) == "-0")
        // Numerically, -0 and 0 are still the same value.
        #expect(decoded == .integer(0))
    }

    // MARK: - Canonical equivalence

    @Test(
        "Differently-spelled numerals with the same value compare equal",
        arguments: [
            ("150", "1.5e2"),
            ("150", "15e1"),
            ("150", "0.150e3"),
            ("4242", "4242.0"),
            ("0.5", "5e-1"),
        ]
    )
    func canonicallyEquivalentSpellingsCompareEqual(spellings: (String, String)) throws {
        let (lhs, rhs) = spellings
        let left = try ContractJSON.decode(JSONNumber.self, from: Data(lhs.utf8))
        let right = try ContractJSON.decode(JSONNumber.self, from: Data(rhs.utf8))
        #expect(left == right)
        #expect(left.hashValue == right.hashValue)
        // Despite comparing equal, each retains its own original spelling.
        #expect(left.rawToken == lhs)
        #expect(right.rawToken == rhs)
    }

    @Test("Numerically distinct numerals do not compare equal")
    func distinctNumeralsCompareUnequal() throws {
        let smaller = try ContractJSON.decode(JSONNumber.self, from: Data("150".utf8))
        let larger = try ContractJSON.decode(JSONNumber.self, from: Data("151".utf8))
        #expect(smaller != larger)
    }

    // MARK: - Malformed/nonfinite programmatic construction

    @Test("An empty coefficient is rejected")
    func emptyCoefficientRejected() {
        #expect(throws: JSONNumber.ValidationError.emptyCoefficient) {
            try JSONNumber(coefficient: "", exponent: 0)
        }
    }

    @Test("A non-digit coefficient is rejected")
    func nonDigitCoefficientRejected() {
        #expect(throws: JSONNumber.ValidationError.nonDigitCoefficient) {
            try JSONNumber(coefficient: "12a3", exponent: 0)
        }
    }

    @Test("A coefficient with a leading zero (other than exactly \"0\") is rejected")
    func leadingZeroCoefficientRejected() {
        #expect(throws: JSONNumber.ValidationError.leadingZeroCoefficient) {
            try JSONNumber(coefficient: "0123", exponent: 0)
        }
    }

    @Test("A lone \"0\" coefficient is accepted")
    func loneZeroCoefficientAccepted() throws {
        let number = try JSONNumber(coefficient: "0", exponent: 5)
        #expect(number.coefficient == "0")
    }

    @Test("Double.nan cannot construct a JSONNumber")
    func nanDoubleRejected() {
        #expect(throws: JSONNumber.ValidationError.nonfiniteValue) {
            try JSONNumber(double: .nan)
        }
    }

    @Test("Double.infinity and -.infinity cannot construct a JSONNumber")
    func infiniteDoubleRejected() {
        #expect(throws: JSONNumber.ValidationError.nonfiniteValue) {
            try JSONNumber(double: .infinity)
        }
        #expect(throws: JSONNumber.ValidationError.nonfiniteValue) {
            try JSONNumber(double: -.infinity)
        }
    }

    @Test("Decimal.nan cannot construct a JSONNumber")
    func nanDecimalRejected() {
        #expect(throws: JSONNumber.ValidationError.nonfiniteValue) {
            try JSONNumber.decimal(.nan)
        }
    }

    @Test("A finite Double constructs an exact JSONNumber")
    func finiteDoubleConstructs() throws {
        let number = try JSONNumber(double: 42.5)
        #expect(try number == (ContractJSON.decode(JSONNumber.self, from: Data("42.5".utf8))))
    }

    // MARK: - Encoding through a stock JSONEncoder never silently truncates

    @Test("Encoding a too-precise JSONNumber through a stock JSONEncoder rejects it")
    func stockEncoderRefusesLossyNumber() throws {
        let number = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("1.000000000000000000000000000000000000001".utf8)
        )
        #expect(throws: (any Error).self) {
            try JSONEncoder().encode(number)
        }
    }

    @Test("Encoding a representable JSONNumber through a stock JSONEncoder succeeds")
    func stockEncoderAcceptsRepresentableNumber() throws {
        let number = JSONNumber.integer(4242)
        let data = try JSONEncoder().encode(number)
        #expect(String(data: data, encoding: .utf8) == "4242")
    }

    // MARK: - Byte-level re-encode semantics

    @Test(
        "A parsed value re-encodes to the exact same bytes it was parsed from",
        arguments: [
            "0", "-0", "42", "-42", "4242.5", "1e128", "5e-128", "1.5e2",
            "0.00001", "-0.5", "123456789012345678901234567890",
        ]
    )
    func parsedValuesReencodeByteForByte(literal: String) throws {
        let decoded = try ContractJSON.decode(JSONNumber.self, from: Data(literal.utf8))
        let reencoded = try ContractJSON.encode(decoded)
        #expect(reencoded == Data(literal.utf8))
    }

    @Test("A programmatically constructed value (no rawToken) renders its canonical plain form")
    func constructedValueRendersCanonicalForm() throws {
        let number = try JSONNumber(sign: .minus, coefficient: "15", exponent: 1)
        #expect(number.rawToken == nil)
        #expect(number.plainDecimalString == "-150")
        let encoded = try ContractJSON.encode(number)
        #expect(String(data: encoded, encoding: .utf8) == "-150")
    }
}
