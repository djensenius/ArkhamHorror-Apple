@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Extreme-exponent adversarial coverage for `JSONNumber` (review round 3, HIGH #1). Split
/// out of ``LosslessJSONNumberTests`` purely to stay under SwiftLint's file/type-length
/// limits; conceptually this is a continuation of that suite's mutation-resistant
/// `JSONNumber` coverage.
///
/// Every value below is at or beyond the boundary a fixed-width `Int` exponent could ever
/// represent. Each of these reproduced a concrete trap or unbounded allocation before
/// `DecimalExponent` replaced `Int` arithmetic throughout this type: the point of every
/// test in this section is simply that the operation *completes* (parses, hashes, compares,
/// converts, or encodes) rather than crashing or attempting an astronomical allocation —
/// most assertions on the *result* are secondary to that.
@Suite("JSONNumber extreme-exponent losslessness")
struct LosslessJSONNumberExtremeExponentTests {
    @Test("A tiny coefficient with a huge negative exponent parses without trapping")
    func tinyCoefficientHugeNegativeExponentParses() throws {
        // Reproduced a subtraction trap: `explicitExponent.adding(-fracDigits.count)` when
        // `explicitExponent` is already at the negative extreme.
        let literal = "0.00e-9223372036854775807"
        let decoded = try ContractJSON.decode(JSONNumber.self, from: Data(literal.utf8))
        #expect(decoded.isZero)
        // Legitimate zero (not underflow): canonical form collapses to plain "0".
        #expect(decoded == .integer(0))
    }

    @Test("A huge positive exponent hashes without trapping")
    func hugePositiveExponentHashes() throws {
        // Reproduced an increment trap in `canonicalTriple`'s trailing-zero trim
        // (`exp.adding(1)`) when `exponent` is already at `Int64.max`.
        let decoded = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("10e9223372036854775807".utf8)
        )
        var hasher = Hasher()
        decoded.hash(into: &hasher)
        _ = hasher.finalize() // must not trap
        // "10e9223372036854775807" canonicalizes to coefficient "1", exponent
        // 9223372036854775808 (one past Int64.max) after trimming the trailing zero.
        let equivalent = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("1e9223372036854775808".utf8)
        )
        #expect(decoded == equivalent)
        #expect(decoded.hashValue == equivalent.hashValue)
    }

    @Test("A huge positive exponent cannot be expanded, but does not attempt to allocate")
    func hugePositiveExponentConversionIsBounded() throws {
        // Reproduced an enormous `String(repeating:)` allocation attempt in
        // `plainDecimalString`/`wholeNumberMagnitude` when converting this exponent to a
        // fixed-width `Int` and using it directly as a zero-padding count.
        let decoded = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("1e9223372036854775807".utf8)
        )
        #expect(decoded.plainDecimalString == nil)
        #expect(decoded.wholeNumberMagnitude == nil)
        // `description`/encode must still succeed via the bounded scientific-notation
        // fallback (bounded by coefficient's and exponent's own digit counts, not by the
        // astronomical value the exponent encodes).
        #expect(decoded.rawToken == "1e9223372036854775807")
        let reencoded = try ContractJSON.encode(decoded)
        #expect(String(data: reencoded, encoding: .utf8) == "1e9223372036854775807")
    }

    @Test("Exponent exactly at Int64.max and Int64.min are both representable as Int")
    func exponentAtInt64BoundariesConvertsToInt() throws {
        let maxDecoded = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("1e9223372036854775807".utf8)
        )
        #expect(maxDecoded.exponent.asInt == Int.max)
        let minDecoded = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("1e-9223372036854775808".utf8)
        )
        #expect(minDecoded.exponent.asInt == Int.min)
    }

    @Test("Exponent one past Int64.max/Int64.min is parsed exactly but not Int-representable")
    func exponentOnePastInt64BoundariesIsNotIntRepresentable() throws {
        let onePastMax = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("1e9223372036854775808".utf8)
        )
        #expect(onePastMax.exponent.asInt == nil)
        let onePastMin = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("1e-9223372036854775809".utf8)
        )
        #expect(onePastMin.exponent.asInt == nil)
    }

    @Test("Zero with a huge positive or negative exponent is still exactly zero")
    func zeroWithHugeExponentIsStillZero() throws {
        let hugePositive = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("0e9223372036854775807".utf8)
        )
        let hugeNegative = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("0e-9223372036854775807".utf8)
        )
        #expect(hugePositive.isZero)
        #expect(hugeNegative.isZero)
        #expect(hugePositive == .integer(0))
        #expect(hugeNegative == .integer(0))
        #expect(hugePositive == hugeNegative)
    }

    @Test("A many-zero coefficient canonicalizes (trims) without trapping at extreme exponents")
    func longZeroPaddedCoefficientCanonicalizes() throws {
        // "10...0" (200 trailing zeros) at an already-huge exponent: canonicalization must
        // trim every trailing zero from the coefficient via repeated `adding(1)` calls
        // without trapping, however large the starting exponent already is.
        let coefficient = "1" + String(repeating: "0", count: 200)
        let decoded = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("\(coefficient)e9223372036854775000".utf8)
        )
        let equivalent = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("1e9223372036854775200".utf8)
        )
        #expect(decoded == equivalent)
    }

    @Test("DecimalExponent.asInt handles exact Int boundaries and one-past values")
    func decimalExponentAsIntBoundaries() {
        #expect(DecimalExponent(Int.max).asInt == Int.max)
        #expect(DecimalExponent(Int.min).asInt == Int.min)
        let onePastMax = DecimalExponent(sign: .plus, digits: Array("9223372036854775808".utf8))
        #expect(onePastMax.asInt == nil)
        let onePastMin = DecimalExponent(sign: .minus, digits: Array("9223372036854775809".utf8))
        #expect(onePastMin.asInt == nil)
    }

    @Test("A negative-exponent value beyond Int64's range parses, hashes, and re-encodes")
    func negativeExponentBeyondInt64Range() throws {
        let literal = "3e-99999999999999999999999999999999999999"
        let decoded = try ContractJSON.decode(JSONNumber.self, from: Data(literal.utf8))
        var hasher = Hasher()
        decoded.hash(into: &hasher)
        _ = hasher.finalize()
        #expect(decoded.plainDecimalString == nil)
        let reencoded = try ContractJSON.encode(decoded)
        #expect(String(data: reencoded, encoding: .utf8) == literal)
    }
}
