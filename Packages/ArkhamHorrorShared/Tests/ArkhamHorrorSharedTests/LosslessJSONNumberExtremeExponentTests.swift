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

    // MARK: - Round 6: leading-zero normalization must be O(n), not O(n^2)

    @Test("A many-leading-zero exponent normalizes without quadratic blowup")
    func manyLeadingZeroExponentNormalizesLinearly() throws {
        // Round 6 HIGH #1: `DecimalExponent.init(sign:digits:)` previously trimmed leading
        // zeros by converting to a `Substring` and looping `trimmed.count > 1 { trimmed.
        // removeFirst() }`. `Substring.count` walks the *entire* remaining substring's
        // grapheme clusters on every call, making the whole trim O(n^2) in the exponent's
        // own digit count. The reviewer measured 160,000 leading zeros at ~28.85s pre-fix;
        // this single decode of a comparably sized exponent is a structural correctness
        // assertion (exact decoded value), not a timing one -- a regression back to
        // quadratic behavior would make this one decode (and the whole suite) unusably
        // slow rather than silently pass.
        let manyZeros = String(repeating: "0", count: 200_000)
        let literal = "1e\(manyZeros)1"
        let decoded = try ContractJSON.decode(JSONNumber.self, from: Data(literal.utf8))
        // 200,000 leading zeros followed by a trailing "1" normalizes to exponent 1, exactly.
        #expect(decoded.exponent.asInt == 1)
        let equivalent = try ContractJSON.decode(JSONNumber.self, from: Data("1e1".utf8))
        #expect(decoded == equivalent)
        #expect(decoded.hashValue == equivalent.hashValue)
    }

    @Test("An all-zero exponent of many digits still normalizes to a plain zero exponent")
    func allZeroExponentNormalizesToZero() throws {
        // Regression guard for the trim loop's "stop before consuming the last digit"
        // invariant: an exponent that is *entirely* zeros (no trailing nonzero digit) must
        // still normalize correctly rather than trimming away every digit.
        let manyZeros = String(repeating: "0", count: 200_000)
        let decoded = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("5e\(manyZeros)".utf8)
        )
        #expect(decoded.exponent.asInt == 0)
        #expect(decoded == .integer(5))
    }

    @Test("A many-leading-zero coefficient normalizes without quadratic blowup")
    func manyLeadingZeroCoefficientNormalizesLinearly() throws {
        // Round 6 MEDIUM #2: `parseNumber()` previously combined the integer+fraction digit
        // runs into an `[UInt8]` `Array` and trimmed leading zeros via `digits.
        // removeFirst()`. `Array.removeFirst()` shifts every remaining element on each
        // call, making the trim O(n^2) in the coefficient's own digit count -- triggered by
        // inputs like "0.000...0001" with many leading fractional zeros.
        let manyZeros = String(repeating: "0", count: 200_000)
        let literal = "0.\(manyZeros)1"
        let decoded = try ContractJSON.decode(JSONNumber.self, from: Data(literal.utf8))
        let equivalent = try ContractJSON.decode(JSONNumber.self, from: Data("1e-200001".utf8))
        #expect(decoded == equivalent)
        #expect(decoded.hashValue == equivalent.hashValue)
        #expect(!decoded.isZero)
    }

    @Test("Zero and negative zero still normalize correctly after the coefficient-trim fix")
    func zeroAndNegativeZeroStillNormalizeAfterCoefficientTrimFix() throws {
        let manyZeros = String(repeating: "0", count: 50000)
        let plainZero = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("0.\(manyZeros)".utf8)
        )
        let negativeZero = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("-0.\(manyZeros)".utf8)
        )
        #expect(plainZero.isZero)
        #expect(negativeZero.isZero)
        #expect(plainZero == .integer(0))
        #expect(negativeZero == .integer(0))
    }
}
