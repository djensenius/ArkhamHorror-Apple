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
/// Single source of truth for the environment-variable keys shared between each
/// subprocess-guard call site below and its corresponding victim test. Duplicating these
/// as independent string literals in two places was flagged as a producer/consumer drift
/// risk: a typo in either copy would make the victim's `ProcessInfo` lookup silently miss,
/// causing it to no-op (return immediately, "passing" trivially) while the parent still
/// saw a healthy zero exit code and could wrongly report a genuine pass. (In addition to
/// this shared-constant fix, `SubprocessDeadlineGuard` itself independently requires a
/// completion-sentinel proof before treating any exit-0 child as a real pass, which also
/// catches this same failure mode by construction, not merely by convention.)
private enum QuadraticGuardVictimEnvironmentKey {
    static let exponentZeroCount = "QUADRATIC_GUARD_EXPONENT_ZERO_COUNT"
    static let coefficientZeroCount = "QUADRATIC_GUARD_COEFFICIENT_ZERO_COUNT"
}

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
        // assertion (exact decoded value), not a timing one.
        let manyZeros = String(repeating: "0", count: 200_000)
        let literal = "1e\(manyZeros)1"
        let decoded = try ContractJSON.decode(JSONNumber.self, from: Data(literal.utf8))
        // 200,000 leading zeros followed by a trailing "1" normalizes to exponent 1, exactly.
        #expect(decoded.exponent.asInt == 1)
        let equivalent = try ContractJSON.decode(JSONNumber.self, from: Data("1e1".utf8))
        #expect(decoded == equivalent)
        #expect(decoded.hashValue == equivalent.hashValue)

        // The assertions above only *report* slowness; a reintroduced quadratic loop would
        // still eventually finish and pass them (the reviewer measured ~45-54s at this same
        // size, not a crash). To give this test actual mutation-detection power, also run
        // the identical parse in a genuinely separate, killable subprocess under a hard,
        // very generous deadline: the fixed (linear) implementation finishes in well under
        // a second even accounting for process-launch overhead, while the old quadratic
        // loop at this size needs ~45-54s -- more than double the deadline below, with a
        // wide non-flaky margin on both sides.
        let outcome = try SubprocessDeadlineGuard.runFiltered(
            victimFilter: "quadraticGuardVictimExponentParse",
            additionalEnvironment: [
                QuadraticGuardVictimEnvironmentKey.exponentZeroCount: "200000",
            ],
            deadlineSeconds: 20
        )
        recordIfSkipped(outcome)
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

        // As above: the old `Array.removeFirst()` trim is only ~O(n) *slower*, not
        // divergent, at this modest size (the reviewer measured ~0.36s at 200,000 zeros --
        // fast enough to still pass an in-process timing check silently). Use a much larger
        // input, still safely under the 16 MiB document cap (~2.9 MB here), in a killable
        // subprocess: the fixed (linear) implementation stays well under a second, while the
        // quadratic `removeFirst()` loop scales with the *square* of the digit count and
        // would need well over a minute -- comfortably exceeding the deadline below by a
        // wide, non-flaky margin.
        let outcome = try SubprocessDeadlineGuard.runFiltered(
            victimFilter: "quadraticGuardVictimCoefficientParse",
            additionalEnvironment: [
                QuadraticGuardVictimEnvironmentKey.coefficientZeroCount: "3000000",
            ],
            deadlineSeconds: 20
        )
        recordIfSkipped(outcome)
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

    // MARK: - Round 8: honest handling of the Xcode bare-xctest host

    /// Round 8 HIGH: under `xcodebuild test` against this package's auto-generated Xcode
    /// scheme, the test host is Apple's classic bare `xctest` agent (`CommandLine.
    /// arguments.count == 1`), which has no `--filter`-shaped argv for
    /// `SubprocessDeadlineGuard` to replay into. Rather than either a false-slow "timed
    /// out" report (appending `--filter` there is silently ignored, so the child would run
    /// the whole bundle) or a silent no-op, an unsupported host is surfaced as a visible,
    /// non-fatal `.warning`-severity issue -- the structural/semantic assertions above
    /// (which do not depend on any subprocess) still ran and still had to pass regardless.
    private func recordIfSkipped(_ outcome: SubprocessDeadlineGuardOutcome) {
        guard case let .skippedUnsupportedHost(reason) = outcome else {
            return
        }
        _ = Issue.record(
            Comment(
                rawValue: "SubprocessDeadlineGuard's subprocess mutation-detection layer " +
                    "was skipped: \(reason). The structural/semantic assertions above " +
                    "already ran in-process and still had to pass."
            ),
            severity: .warning
        )
    }

    // MARK: - Round 7: subprocess victims backing the deadline guards above

    // These two are never invoked directly by the full-suite run itself: swift-testing
    // discovers and would otherwise execute them too, so each is a no-op (instant pass)
    // unless its corresponding environment variable is present, which only
    // `SubprocessDeadlineGuard.runFiltered` sets, and only in the dedicated child process it
    // launches. Their function names double as the `--filter` argument that isolates them
    // from the rest of the suite in that child process, so each name must stay unique. Each
    // calls `SubprocessDeadlineGuard.recordVictimCompletion()` as its very last step,
    // strictly after its own assertions have already passed, so the parent can tell a
    // genuine pass apart from a child that exited 0 without ever running this code (round 8
    // LOW: a missing/mismatched trigger environment variable must not be silently treated
    // as a pass).

    @Test("Quadratic-guard victim: exponent leading-zero parse (subprocess-only)")
    func quadraticGuardVictimExponentParse() throws {
        guard
            let raw = ProcessInfo.processInfo
            .environment[QuadraticGuardVictimEnvironmentKey.exponentZeroCount],
            let zeroCount = Int(raw)
        else {
            return
        }
        let manyZeros = String(repeating: "0", count: zeroCount)
        let literal = "1e\(manyZeros)1"
        let decoded = try ContractJSON.decode(JSONNumber.self, from: Data(literal.utf8))
        #expect(decoded.exponent.asInt == 1)
        let equivalent = try ContractJSON.decode(JSONNumber.self, from: Data("1e1".utf8))
        #expect(decoded == equivalent)
        SubprocessDeadlineGuard.recordVictimCompletion()
    }

    @Test("Quadratic-guard victim: coefficient leading-zero parse (subprocess-only)")
    func quadraticGuardVictimCoefficientParse() throws {
        guard
            let raw = ProcessInfo.processInfo
            .environment[QuadraticGuardVictimEnvironmentKey.coefficientZeroCount],
            let zeroCount = Int(raw)
        else {
            return
        }
        let manyZeros = String(repeating: "0", count: zeroCount)
        let literal = "0.\(manyZeros)1"
        let decoded = try ContractJSON.decode(JSONNumber.self, from: Data(literal.utf8))
        let equivalent = try ContractJSON.decode(
            JSONNumber.self,
            from: Data("1e-\(zeroCount + 1)".utf8)
        )
        #expect(decoded == equivalent)
        #expect(!decoded.isZero)
        SubprocessDeadlineGuard.recordVictimCompletion()
    }
}
