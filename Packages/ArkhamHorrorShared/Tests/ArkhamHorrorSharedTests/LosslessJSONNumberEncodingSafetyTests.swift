@testable import ArkhamHorrorShared
import Foundation
import Testing

/// `rawToken` injection safety and Double/Float encode/decode boundary coverage for
/// `JSONNumber` (review round 3, MEDIUM #3/#4/#5). Split out of ``LosslessJSONNumberTests``
/// purely to stay under SwiftLint's file/type-length limits; conceptually this is a
/// continuation of that suite's mutation-resistant `JSONNumber` coverage.
@Suite("JSONNumber rawToken safety and floating-point boundaries")
struct LosslessJSONNumberEncodingSafetyTests {
    // MARK: - `rawToken` cannot be used to inject structure (review round 3, MEDIUM #3)

    /// The validating public initializer never accepts a `rawToken` at all, so a value
    /// built through it can never carry caller-supplied bytes distinct from its own
    /// (safely-bounded, canonical) `description`.
    @Test("The validating public initializer never produces a rawToken")
    func validatingInitializerNeverProducesRawToken() throws {
        let number = try JSONNumber(sign: .minus, coefficient: "42", exponent: 3)
        #expect(number.rawToken == nil)
    }

    /// A coefficient containing structural JSON bytes (comma, quote, colon) is exactly the
    /// shape an injection attempt would need — and it is rejected outright as
    /// non-numeric, long before any question of `rawToken` arises.
    @Test("An injection-shaped coefficient is rejected, never smuggled into rawToken")
    func injectionShapedCoefficientRejected() {
        #expect(throws: JSONNumber.ValidationError.nonDigitCoefficient) {
            try JSONNumber(coefficient: "1,\"injected\":true", exponent: 0)
        }
    }

    /// `init(exactDecimalLiteral:)` requires the scanner to be exactly at the end of the
    /// numeral once parsing finishes — so appending trailing structure after a genuine
    /// numeral (the injection shape the review specifically cites) is rejected rather than
    /// silently accepted with the trailing bytes discarded or retained.
    @Test("Trailing structure after a genuine numeral is rejected by exactDecimalLiteral")
    func trailingStructureAfterNumeralRejectedByExactDecimalLiteral() {
        #expect(throws: (any Error).self) {
            try JSONNumber(exactDecimalLiteral: "1,\"injected\":true")
        }
    }

    /// Every public, non-parser construction path — not just the validating
    /// `init(sign:coefficient:exponent:)` — must leave `rawToken` `nil`. This is the
    /// complete enumeration of every public factory `JSONNumber` exposes besides
    /// ``JSONNumber/parsed(sign:coefficient:exponent:rawToken:)`` (which is documented as
    /// parser-exclusive and is never called from production request/response construction
    /// code, only from `LosslessJSONByteScannerNumbers.parseNumber()`).
    @Test("Any rawToken a public constructor produces is self-consistent and injection-free")
    func anyPublicRawTokenIsSelfConsistentAndInjectionFree() throws {
        // `.integer`/`.unsignedInteger`/the raw validating initializer bypass numeral
        // formatting entirely and leave `rawToken` `nil`. `.decimal`/`init(double:)`/
        // `init(float:)` format their own value's text and re-parse *that* through the same
        // safe grammar the wire parser uses, which is where their (self-generated, never
        // caller-supplied) `rawToken` comes from.
        let numbers: [JSONNumber] = try [
            .integer(42),
            .integer(-42),
            .unsignedInteger(42),
            .decimal(#require(Decimal(string: "3.14"))),
            JSONNumber(double: 3.14),
            JSONNumber(float: 3.14),
            JSONNumber(sign: .plus, coefficient: "0", exponent: 0),
        ]
        let allowedCharacters = Set("0123456789.eE+-")
        for number in numbers {
            guard let rawToken = number.rawToken else { continue }
            // Every character must belong to JSON's numeral grammar — no structural byte
            // (comma, quote, colon, brace, bracket, whitespace) can appear, which is exactly
            // what an injection attempt (`1,"injected":true`) would require.
            #expect(rawToken.allSatisfy { allowedCharacters.contains($0) })
            // Re-parsing it from scratch through the same safe grammar must reproduce an
            // equal value: the rawToken never spells anything other than exactly what its
            // own already-validated components mean.
            let reparsed = try JSONNumber(exactDecimalLiteral: rawToken)
            #expect(reparsed == number)
        }
    }

    /// A value the parser itself produces from a legitimate, single numeral can never
    /// disagree with its own `rawToken`: the numeral the serializer re-emits (via
    /// `description`, which prefers `rawToken` when present) is provably the exact same
    /// bytes the parser consumed for that one number, inside a larger document, with
    /// nothing before or after it belonging to a different value.
    @Test("A parsed number embedded in a larger document re-serializes to exactly itself")
    func parsedNumberEmbeddedInDocumentReserializesExactly() throws {
        let document = Data(#"{"a":1,"n":123.456e7,"b":2}"#.utf8)
        let value = try LosslessJSONParser.parse(document)
        guard case let .object(fields) = value, let numberValue = fields["n"] else {
            Issue.record("Expected an object with an \"n\" key")
            return
        }
        guard case let .number(number) = numberValue else {
            Issue.record("Expected \"n\" to decode as a number")
            return
        }
        #expect(number.rawToken == "123.456e7")
        let reserialized = try LosslessJSONSerializer.serialize(numberValue)
        #expect(String(data: reserialized, encoding: .utf8) == "123.456e7")
    }

    // MARK: - Double/Float encoding never routes through `Decimal` (review round 3, MEDIUM #4)

    private func roundTripDouble(_ value: Double) throws -> Double {
        let encoded = try ContractJSON.encode(value)
        return try ContractJSON.decode(Double.self, from: encoded)
    }

    private func roundTripFloat(_ value: Float) throws -> Float {
        let encoded = try ContractJSON.encode(value)
        return try ContractJSON.decode(Float.self, from: encoded)
    }

    @Test("Double.leastNonzeroMagnitude (subnormal) round-trips exactly")
    func doubleLeastNonzeroMagnitudeRoundTrips() throws {
        let value = Double.leastNonzeroMagnitude
        #expect(try roundTripDouble(value) == value)
        #expect(try roundTripDouble(-value) == -value)
    }

    @Test("Double.greatestFiniteMagnitude round-trips exactly")
    func doubleGreatestFiniteMagnitudeRoundTrips() throws {
        let value = Double.greatestFiniteMagnitude
        #expect(try roundTripDouble(value) == value)
        #expect(try roundTripDouble(-value) == -value)
    }

    @Test("A Double around 1e200/1e-200 round-trips exactly")
    func doubleExtremeMagnitudesRoundTrip() throws {
        #expect(try roundTripDouble(1e200) == 1e200)
        #expect(try roundTripDouble(1e-200) == 1e-200)
        #expect(try roundTripDouble(-1e200) == -1e200)
    }

    @Test("Double -0.0's sign bit is preserved through encode/decode")
    func doubleNegativeZeroSignPreserved() throws {
        let encoded = try ContractJSON.encode(-0.0 as Double)
        // The encoder must actually distinguish -0 from 0 in the wire bytes, not merely in
        // an in-memory `JSONNumber.sign`.
        #expect(String(data: encoded, encoding: .utf8) == "-0.0")
        let decoded = try ContractJSON.decode(Double.self, from: encoded)
        #expect(decoded.sign == .minus)
        #expect(decoded.bitPattern == (-0.0 as Double).bitPattern)
    }

    @Test("An ordinary finite Double round-trips exactly")
    func ordinaryDoubleRoundTrips() throws {
        #expect(try roundTripDouble(3.14159265358979) == 3.14159265358979)
    }

    @Test("Float.leastNonzeroMagnitude (subnormal) round-trips exactly")
    func floatLeastNonzeroMagnitudeRoundTrips() throws {
        let value = Float.leastNonzeroMagnitude
        #expect(try roundTripFloat(value) == value)
        #expect(try roundTripFloat(-value) == -value)
    }

    @Test("Float.greatestFiniteMagnitude round-trips exactly")
    func floatGreatestFiniteMagnitudeRoundTrips() throws {
        let value = Float.greatestFiniteMagnitude
        #expect(try roundTripFloat(value) == value)
        #expect(try roundTripFloat(-value) == -value)
    }

    @Test("Float -0.0's sign bit is preserved through encode/decode")
    func floatNegativeZeroSignPreserved() throws {
        let encoded = try ContractJSON.encode(-0.0 as Float)
        #expect(String(data: encoded, encoding: .utf8) == "-0.0")
        let decoded = try ContractJSON.decode(Float.self, from: encoded)
        #expect(decoded.sign == .minus)
        #expect(decoded.bitPattern == (-0.0 as Float).bitPattern)
    }

    @Test("Nonfinite Double/Float construction is rejected, not silently substituted")
    func nonfiniteConstructionRejected() {
        #expect(throws: JSONNumber.ValidationError.nonfiniteValue) {
            try JSONNumber(double: .nan)
        }
        #expect(throws: JSONNumber.ValidationError.nonfiniteValue) {
            try JSONNumber(double: .infinity)
        }
        #expect(throws: JSONNumber.ValidationError.nonfiniteValue) {
            try JSONNumber(double: -.infinity)
        }
        #expect(throws: JSONNumber.ValidationError.nonfiniteValue) {
            try JSONNumber(float: .nan)
        }
        #expect(throws: JSONNumber.ValidationError.nonfiniteValue) {
            try JSONNumber(float: .infinity)
        }
    }

    // MARK: - Decoding rejects nonfinite/underflowed results (review round 3, MEDIUM #5)

    @Test("Decoding 1e999 to Double throws instead of silently returning +infinity")
    func decodingHugeMagnitudeToDoubleThrows() {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(Double.self, from: Data("1e999".utf8))
        }
    }

    @Test("Decoding -1e999 to Double throws instead of silently returning -infinity")
    func decodingHugeNegativeMagnitudeToDoubleThrows() {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(Double.self, from: Data("-1e999".utf8))
        }
    }

    @Test("Decoding a nonzero 1e-999 to Double throws instead of silently returning 0")
    func decodingTinyNonzeroMagnitudeToDoubleThrows() {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(Double.self, from: Data("1e-999".utf8))
        }
    }

    @Test("Decoding a nonzero -1e-999 to Double throws instead of silently returning -0")
    func decodingTinyNegativeNonzeroMagnitudeToDoubleThrows() {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(Double.self, from: Data("-1e-999".utf8))
        }
    }

    @Test("Decoding genuine zero at a huge exponent to Double still succeeds as (signed) zero")
    func decodingGenuineZeroAtHugeExponentToDoubleSucceeds() throws {
        let positive = try ContractJSON.decode(Double.self, from: Data("0e999".utf8))
        #expect(positive == 0)
        #expect(positive.sign == .plus)
        let negative = try ContractJSON.decode(Double.self, from: Data("-0e999".utf8))
        #expect(negative == 0)
        #expect(negative.sign == .minus)
    }

    @Test("Decoding 1e999/1e-999 to Float throws the same way as Double")
    func decodingExtremeMagnitudesToFloatThrows() {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(Float.self, from: Data("1e999".utf8))
        }
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(Float.self, from: Data("1e-999".utf8))
        }
    }

    @Test("Decoding a magnitude that overflows only Float, not Double, throws for Float")
    func decodingFloatOverflowingMagnitudeThrows() {
        // 1e100 is well within Double's range but far beyond Float's ~3.4e38 max.
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(Float.self, from: Data("1e100".utf8))
        }
    }
}
