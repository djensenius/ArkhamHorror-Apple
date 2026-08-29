import Foundation

/// ``JSONNumber``'s canonical (sign/coefficient/exponent) normalization, `Equatable`/
/// `Hashable` conformance, fixed-width/plain-decimal rendering, and `CustomStringConvertible`
/// description. Kept in its own file (and not in `JSONNumber.swift` itself) purely to stay
/// under SwiftLint's file-length limit; nothing here needs access to `JSONNumber`'s private
/// `uncheckedSign` initializer or its `fileprivate` `parsed(...)` factory, so — unlike
/// `JSONNumber.swift`'s `Codable` extension and `LosslessJSONByteScanner.parseNumber()` —
/// none of it needs to be colocated with those unsafe-construction seams to enforce that
/// access restriction.
extension JSONNumber {
    /// This value rendered as plain decimal digits (no exponent letter), expanding the
    /// exponent into literal trailing zeros or a decimal point. `nil` when that expansion
    /// would require producing more than ``maxExpansionDigitCount`` digits (an
    /// astronomically large parsed exponent) — callers needing *some* safely-bounded
    /// rendering regardless should use ``description`` instead, which falls back to compact
    /// scientific notation in that case.
    var plainDecimalString: String? {
        // Zero is always exactly "0" regardless of how large (in either direction) its
        // exponent is: short-circuiting here means this never even asks how many digits
        // that exponent would expand to, let alone attempts an allocation proportional to
        // it (an all-zero coefficient paired with an astronomical exponent is exactly the
        // kind of remote-data input this must handle without excess work).
        guard !isZero else { return "0" }
        let signPrefix = sign == .minus ? "-" : ""
        switch exponent.sign {
        case .plus:
            guard let exponentValue = exponent.magnitudeIfAtMost(Self.maxExpansionDigitCount)
            else { return nil }
            return signPrefix + coefficient + String(repeating: "0", count: exponentValue)
        case .minus:
            // `magnitudeIfAtMost` bounds this to `0...maxExpansionDigitCount` directly from
            // `exponent`'s sign+magnitude representation — never by negating a fixed-width
            // `Int`, so an exponent at (or beyond) `Int.min` can never trap here.
            guard let fractionDigits = exponent.magnitudeIfAtMost(Self.maxExpansionDigitCount)
            else { return nil }
            if fractionDigits >= coefficient.count {
                let padding = String(repeating: "0", count: fractionDigits - coefficient.count)
                return signPrefix + "0." + padding + coefficient
            }
            let splitIndex = coefficient.index(coefficient.endIndex, offsetBy: -fractionDigits)
            return signPrefix + coefficient[..<splitIndex] + "." + coefficient[splitIndex...]
        }
    }

    /// Whether this value's exact numeric value is zero, regardless of sign, exponent, or
    /// how many (possibly redundant) digits ``coefficient`` spells it with (`"0"`, `"00"`,
    /// and `"0"` at any exponent are all zero).
    var isZero: Bool {
        coefficient.allSatisfy { $0 == "0" }
    }

    /// This value's exact digits as an unsigned whole number (for example `100`, `1e2`, and
    /// `1.00` all yield `"100"`/`"1"`/`"100"` respectively), if it represents an integer
    /// with no nonzero fractional remainder. `nil` for values like `1.5` that are not whole
    /// numbers, and for a whole number whose expansion would exceed
    /// ``maxExpansionDigitCount`` digits.
    var wholeNumberMagnitude: String? {
        // See `plainDecimalString`: zero is a whole number ("0") regardless of its
        // exponent's magnitude, so this must never even compute a fraction-digit count —
        // let alone negate one — for an all-zero coefficient.
        guard !isZero else { return "0" }
        switch exponent.sign {
        case .plus:
            guard let exponentValue = exponent.magnitudeIfAtMost(Self.maxExpansionDigitCount)
            else { return nil }
            return coefficient + String(repeating: "0", count: exponentValue)
        case .minus:
            // Bounded, sign-aware magnitude extraction — never a fixed-width `Int`
            // negation — so an exponent at (or beyond) `Int.min` (for example
            // `1e-9223372036854775808`) can only ever fail this `guard`, never trap.
            guard let fractionDigits = exponent.magnitudeIfAtMost(Self.maxExpansionDigitCount)
            else { return nil }
            guard fractionDigits < coefficient.count else {
                // Already known non-zero (checked above), so a fractional magnitude at
                // least as large as every coefficient digit can only be a genuine
                // fraction, never a whole number.
                return nil
            }
            let splitIndex = coefficient.index(coefficient.endIndex, offsetBy: -fractionDigits)
            guard coefficient[splitIndex...].allSatisfy({ $0 == "0" }) else { return nil }
            let whole = String(coefficient[..<splitIndex])
            return whole.isEmpty ? "0" : whole
        }
    }

    /// A `(sign, coefficient, exponent)` triple with every common trailing zero folded out
    /// of the coefficient and into the exponent, and zero normalized to a single canonical
    /// form regardless of sign or spelling. Two numbers spelled differently but equal in
    /// value (`150`, `1.50e2`, `15e1`) always share this triple.
    struct CanonicalTriple: Equatable {
        let sign: Sign
        let coefficient: String
        let exponent: DecimalExponent
    }

    private var canonicalTriple: CanonicalTriple {
        if isZero {
            return CanonicalTriple(sign: .plus, coefficient: "0", exponent: .zero)
        }
        // Count every trailing zero once (a single reverse scan), then trim them all with
        // one slice and fold them into the exponent with exactly one `adding` call. The
        // previous implementation removed one zero and called `exp.adding(1)` per
        // iteration: for a coefficient with `n` trailing zeros and an exponent whose own
        // digit count is already `m` (both attacker-controllable from remote numeral
        // text), that was `O(n * m)` digit-arithmetic work. This is `O(n + m)`: one scan to
        // count, one slice to trim, one exact addition to shift the exponent.
        let trailingZeroCount = coefficient.utf8.reversed().prefix(while: { $0 == 0x30 }).count
        guard trailingZeroCount > 0 else {
            return CanonicalTriple(sign: sign, coefficient: coefficient, exponent: exponent)
        }
        // `isZero` is false here, so at least one non-zero digit remains after trimming:
        // this can never leave `coefficient` empty.
        let trimmedCoefficient = String(coefficient.dropLast(trailingZeroCount))
        return CanonicalTriple(
            sign: sign,
            coefficient: trimmedCoefficient,
            exponent: exponent.adding(trailingZeroCount)
        )
    }

    /// Attempts an exact (never rounded) `Decimal` reconstruction, verified by re-parsing
    /// the resulting `Decimal`'s own description and confirming it is canonically equal to
    /// `self`. `nil` when `Decimal` cannot represent this value exactly (including when
    /// `self`'s own plain-decimal expansion is too large to even attempt).
    ///
    /// `internal`, not `private`: `JSONNumber.swift`'s `Codable` extension (kept in that
    /// file because it also needs the private `uncheckedSign` initializer) calls this from
    /// across the file boundary. Exposing this normalization detail module-wide is safe —
    /// unlike `uncheckedSign`/`parsed(...)`, nothing here can construct an invalid
    /// `JSONNumber`; it only ever reads an existing one.
    var asExactDecimal: Decimal? {
        guard let expanded = plainDecimalString else { return nil }
        let locale = Locale(identifier: "en_US")
        guard let value = Decimal(string: expanded, locale: locale) else {
            return nil
        }
        guard let roundTripped = try? JSONNumber(exactDecimalLiteral: "\(value)") else {
            return nil
        }
        return roundTripped.canonicalTriple == canonicalTriple ? value : nil
    }
}

extension JSONNumber: Equatable {
    static func == (lhs: JSONNumber, rhs: JSONNumber) -> Bool {
        let left = lhs.canonicalTriple
        let right = rhs.canonicalTriple
        return left.sign == right.sign && left.coefficient == right.coefficient
            && left.exponent == right.exponent
    }
}

extension JSONNumber: Hashable {
    func hash(into hasher: inout Hasher) {
        let triple = canonicalTriple
        hasher.combine(triple.sign)
        hasher.combine(triple.coefficient)
        hasher.combine(triple.exponent)
    }
}

extension JSONNumber: CustomStringConvertible {
    /// The exact original numeral when available (``rawToken``); otherwise a canonical
    /// rendering that is *always* safely bounded regardless of how large ``exponent`` is —
    /// a full plain-decimal expansion when that is boundedly small, or compact scientific
    /// notation (`coefficient` + `"e"` + exponent, with no padding) otherwise. Unlike
    /// unconditionally expanding, this can never attempt an astronomical allocation:
    /// `coefficient`'s own digit count plus `exponent`'s own digit count is always the true
    /// output size here, never the (potentially far larger) *value* `exponent` encodes.
    var description: String {
        if let rawToken {
            return rawToken
        }
        if let expanded = plainDecimalString {
            return expanded
        }
        let signPrefix = sign == .minus ? "-" : ""
        guard !exponent.isZero else { return signPrefix + coefficient }
        return signPrefix + coefficient + "e" + exponent.description
    }
}
