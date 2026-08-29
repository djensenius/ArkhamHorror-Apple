import Foundation

/// A finite, arbitrary-precision JSON number: `sign * coefficient * 10^exponent`.
///
/// Backend identifiers and numeric literals may exceed what any of Foundation's
/// fixed-precision numeric types can hold exactly: `Double` loses bits beyond a 53-bit
/// mantissa, `Decimal` rounds beyond roughly 38 significant digits and cannot represent an
/// exponent much past +/-128, and `Int64` overflows past ~19 digits. This type never
/// converts a parsed numeral through any of them for storage — `coefficient` is an
/// unbounded string of decimal digits and `exponent` is an arbitrary-precision
/// ``DecimalExponent`` (never a fixed-width `Int`), so a literal like
/// `1.000000000000000000000000000000000000001`, `1e128`, or even an exponent whose own
/// digit count exceeds what `Int64` could hold (`1e9223372036854775807` and beyond)
/// round-trips exactly, and no arithmetic this type performs on `exponent` can overflow or
/// trap regardless of how large a parsed exponent already is.
///
/// There is no representation for NaN or infinity: every value this type can hold is
/// finite by construction, and every initializer that could receive a nonfinite input
/// (``decimal(_:)``, ``init(double:)``, ``init(float:)``) validates and throws rather than
/// silently constructing something that later encodes as invalid JSON.
struct JSONNumber: Sendable {
    enum Sign: Sendable, Equatable, Hashable {
        case plus
        case minus
    }

    enum ValidationError: Error, Equatable, Sendable {
        case emptyCoefficient
        case nonDigitCoefficient
        case leadingZeroCoefficient
        case nonfiniteValue
    }

    /// A conservative ceiling on how many digits a plain-decimal expansion (padding
    /// ``coefficient`` out with literal zeros, or splitting it around a decimal point) is
    /// ever allowed to produce. Far beyond any legitimate contract value — this exists
    /// purely to reject expanding an astronomically large *parsed* exponent (for example
    /// `1e9223372036854775807`) before attempting to allocate a string of that length, not
    /// to constrain any real backend-representable number.
    static let maxExpansionDigitCount = 1 << 20

    /// The number's sign. Distinguishes `-0` from `0` for round-trip fidelity, even though
    /// the two compare equal (see ``==(_:_:)``).
    let sign: Sign
    /// Decimal digits only (`0`-`9`), most-significant first. Canonical: never empty, and
    /// never has a leading `0` unless the entire coefficient is the single digit `"0"`.
    let coefficient: String
    /// Base-10 exponent: the number's exact value is `sign * coefficient * 10^exponent`.
    let exponent: DecimalExponent
    /// The exact original JSON numeral text, when this value was produced by
    /// ``LosslessJSONParser`` (directly, or indirectly via ``init(exactDecimalLiteral:)``).
    /// `nil` for values constructed through the validating ``init(sign:coefficient:exponent:)``.
    /// ``LosslessJSONEncoder`` reproduces this token byte-for-byte when present.
    let rawToken: String?

    private init(
        uncheckedSign sign: Sign,
        coefficient: String,
        exponent: DecimalExponent,
        rawToken: String?
    ) {
        self.sign = sign
        self.coefficient = coefficient
        self.exponent = exponent
        self.rawToken = rawToken
    }

    /// Constructs a value whose `rawToken` is trusted to be *exactly* the bytes
    /// `LosslessJSONByteScanner` consumed as this one numeral, with `coefficient`/`exponent`
    /// already derived from parsing those same bytes.
    ///
    /// **Do not call this directly outside `parseNumber()`.** This is the one seam in the
    /// entire type that pairs a `rawToken` string with separately-supplied components
    /// without re-validating them against each other — exactly the seam a public API must
    /// never expose, since ``LosslessJSONSerializer`` writes `rawToken` back out completely
    /// unescaped, and a caller-supplied (rather than scanner-derived) `rawToken` could
    /// smuggle arbitrary trailing JSON structure (`1,"injected":true`) straight into a
    /// parent object or array. `parseNumber()` is safe because it builds `coefficient` from
    /// the exact same digit bytes as `rawToken`'s span, so the two can never disagree.
    static func parsed(
        sign: Sign,
        coefficient: String,
        exponent: DecimalExponent,
        rawToken: String
    ) -> JSONNumber {
        JSONNumber(
            uncheckedSign: sign, coefficient: coefficient, exponent: exponent, rawToken: rawToken
        )
    }

    /// Validates and constructs a number from explicit components. `coefficient` must be a
    /// nonempty run of ASCII digits with no leading zero (unless it is exactly `"0"`).
    ///
    /// There is no way to attach a `rawToken` through this initializer: doing so would let a
    /// caller pair arbitrary, unverified bytes with `coefficient`/`exponent` (see
    /// ``parsed(sign:coefficient:exponent:rawToken:)``'s documentation for why that is
    /// unsafe). A value built here always renders through ``description``'s safely-bounded
    /// canonical expansion instead.
    init(sign: Sign = .plus, coefficient: String, exponent: DecimalExponent) throws {
        guard !coefficient.isEmpty else { throw ValidationError.emptyCoefficient }
        guard coefficient.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }) else {
            throw ValidationError.nonDigitCoefficient
        }
        guard coefficient == "0" || coefficient.first != "0" else {
            throw ValidationError.leadingZeroCoefficient
        }
        self.init(uncheckedSign: sign, coefficient: coefficient, exponent: exponent, rawToken: nil)
    }

    /// Parses `text` as a single, complete JSON numeral matching this type's own grammar
    /// (optional leading `-`, integer part, optional `.digits`, optional `e`/`E[+-]digits`)
    /// and constructs the corresponding value with `rawToken` set to `text` itself.
    ///
    /// `sign`/`coefficient`/`exponent` are always *derived* by parsing `text` — never
    /// accepted as a separately-trusted parameter — so the resulting `rawToken` can never
    /// disagree with its own components, and anything left over after the numeral itself
    /// (checked via `isAtEnd`) is rejected rather than silently retained.
    init(exactDecimalLiteral text: String) throws {
        var scanner = LosslessJSONByteScanner(bytes: Array(text.utf8))
        guard let parsed = try? scanner.parseNumber(), scanner.isAtEnd else {
            throw ValidationError.nonDigitCoefficient
        }
        self = parsed
    }

    /// Constructs an exact number from a finite `Double`. Throws for `.nan` and
    /// `.infinity`/`-.infinity` rather than silently constructing a value that cannot be
    /// re-encoded as valid JSON.
    ///
    /// This never routes through `Decimal`: `Decimal` cannot represent every finite
    /// `Double` (its exponent range and 38-digit precision are both smaller than
    /// `Double`'s), which would silently round or reject valid magnitudes and could lose
    /// `-0.0`'s sign. Instead, `Double`'s own shortest round-tripping `description` (which
    /// Swift already guarantees re-parses to the identical `Double`) is fed through the
    /// same grammar used for wire numerals, so the resulting `JSONNumber` is exact for the
    /// `Double` actually held, including subnormals and `-0.0`.
    init(double value: Double) throws {
        guard value.isFinite else { throw ValidationError.nonfiniteValue }
        self = try JSONNumber(exactDecimalLiteral: "\(value)")
    }

    /// Constructs an exact number from a finite `Float`. Throws for `.nan` and
    /// `.infinity`/`-.infinity`.
    ///
    /// `value` is formatted using `Float`'s own shortest round-tripping `description`
    /// directly — never widened to `Double` first. Widening changes the shortest
    /// round-tripping spelling (`Float(0.1).description == "0.1"`, but
    /// `Double(Float(0.1)).description == "0.10000000149011612"`), which would silently
    /// fabricate precision the original `Float` never had.
    init(float value: Float) throws {
        guard value.isFinite else { throw ValidationError.nonfiniteValue }
        self = try JSONNumber(exactDecimalLiteral: "\(value)")
    }

    /// An exact whole-number value. `Int64` is always finite, so this cannot fail.
    static func integer(_ value: Int64) -> JSONNumber {
        let sign: Sign = value < 0 ? .minus : .plus
        // `Int64.min.magnitude` does not fit in `Int64`, so go through `UInt64` first.
        let magnitude = value.magnitude
        return JSONNumber(
            uncheckedSign: sign, coefficient: String(magnitude), exponent: .zero, rawToken: nil
        )
    }

    /// An exact value from a finite `Decimal`. Throws for `Decimal.nan`.
    static func decimal(_ value: Decimal) throws -> JSONNumber {
        guard !value.isNaN else { throw ValidationError.nonfiniteValue }
        return try JSONNumber(exactDecimalLiteral: "\(value)")
    }

    /// This value rendered as plain decimal digits (no exponent letter), expanding the
    /// exponent into literal trailing zeros or a decimal point. `nil` when that expansion
    /// would require producing more than ``maxExpansionDigitCount`` digits (an
    /// astronomically large parsed exponent) — callers needing *some* safely-bounded
    /// rendering regardless should use ``description`` instead, which falls back to compact
    /// scientific notation in that case.
    var plainDecimalString: String? {
        guard let exponentValue = exponent.asInt,
              exponentValue >= -Self.maxExpansionDigitCount,
              exponentValue <= Self.maxExpansionDigitCount
        else {
            return nil
        }
        let signPrefix = sign == .minus ? "-" : ""
        if exponentValue >= 0 {
            return signPrefix + coefficient + String(repeating: "0", count: exponentValue)
        }
        let fractionDigits = -exponentValue
        if fractionDigits >= coefficient.count {
            let padding = String(repeating: "0", count: fractionDigits - coefficient.count)
            return signPrefix + "0." + padding + coefficient
        }
        let splitIndex = coefficient.index(coefficient.endIndex, offsetBy: -fractionDigits)
        return signPrefix + coefficient[..<splitIndex] + "." + coefficient[splitIndex...]
    }

    /// An exact unsigned whole-number value (used for `UInt64` values that may exceed
    /// `Int64.max`).
    static func unsignedInteger(_ value: UInt64) -> JSONNumber {
        JSONNumber(uncheckedSign: .plus, coefficient: String(value), exponent: .zero, rawToken: nil)
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
        guard let exponentValue = exponent.asInt else { return nil }
        if exponentValue >= 0 {
            guard exponentValue <= Self.maxExpansionDigitCount else { return nil }
            return coefficient + String(repeating: "0", count: exponentValue)
        }
        let fractionDigits = -exponentValue
        guard fractionDigits < coefficient.count else {
            return isZero ? "0" : nil
        }
        let splitIndex = coefficient.index(coefficient.endIndex, offsetBy: -fractionDigits)
        guard coefficient[splitIndex...].allSatisfy({ $0 == "0" }) else { return nil }
        let whole = String(coefficient[..<splitIndex])
        return whole.isEmpty ? "0" : whole
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
        var digits = Array(coefficient)
        var exp = exponent
        while digits.count > 1, digits.last == "0" {
            digits.removeLast()
            // `adding(1)` is exact digit-string arithmetic (see `DecimalExponent`), so this
            // can never trap even when `exp` is already at an `Int`-defying magnitude.
            exp = exp.adding(1)
        }
        return CanonicalTriple(sign: sign, coefficient: String(digits), exponent: exp)
    }

    /// Attempts an exact (never rounded) `Decimal` reconstruction, verified by re-parsing
    /// the resulting `Decimal`'s own description and confirming it is canonically equal to
    /// `self`. `nil` when `Decimal` cannot represent this value exactly (including when
    /// `self`'s own plain-decimal expansion is too large to even attempt).
    private var asExactDecimal: Decimal? {
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

/// Implemented by a `Decoder` that can expose the exact original numeral it is currently
/// positioned at, bypassing fixed-precision conversion entirely. Only
/// ``LosslessJSONDecoder`` (used via ``ContractJSON/decode(_:from:)``) conforms; a stock
/// `Decoder` (for example Foundation's `JSONDecoder`) does not, so ``JSONNumber``'s
/// `Decodable` conformance below falls back to a best-effort (and, for extreme values,
/// lossy or failing) reconstruction in that case.
protocol LosslessJSONNumberSource {
    func losslessJSONNumber() throws -> JSONNumber?
}

/// Implemented by an `Encoder` that can accept an exact ``JSONNumber`` directly, rather
/// than only fixed-precision numeric primitives.
protocol LosslessJSONNumberSink {
    func encodeLosslessJSONNumber(_ value: JSONNumber) throws
}

extension JSONNumber: Codable {
    /// The exact value, if `decoder` is a lossless-aware source (see
    /// ``LosslessJSONNumberSource``). `nil` for a stock `Decoder`, which has no way to
    /// expose one.
    private static func losslessValue(from decoder: any Decoder) throws -> JSONNumber? {
        guard let source = decoder as? LosslessJSONNumberSource else { return nil }
        return try source.losslessJSONNumber()
    }

    init(from decoder: any Decoder) throws {
        if let exact = try Self.losslessValue(from: decoder) {
            self = exact
            return
        }
        // Fallback for a stock `Decoder`, which cannot expose the original numeral's raw
        // digit sequence. Best-effort only: see `JSONNumberTests` for concrete values this
        // path rounds or rejects that the canonical, parser-bound path
        // (`ContractJSON.decode`) does not.
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int64.self) {
            self = .integer(intValue)
            return
        }
        let decimalValue = try container.decode(Decimal.self)
        self = try JSONNumber.decimal(decimalValue)
    }

    func encode(to encoder: any Encoder) throws {
        if let sink = encoder as? LosslessJSONNumberSink {
            try sink.encodeLosslessJSONNumber(self)
            return
        }
        var container = encoder.singleValueContainer()
        if exponent.isZero, let intValue = Int64(sign == .minus ? "-\(coefficient)" : coefficient) {
            try container.encode(intValue)
            return
        }
        guard let decimalValue = asExactDecimal else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: """
                    This JSON number's precision exceeds what a standard JSONEncoder can \
                    represent without loss. Encode through ContractJSON instead.
                    """
                )
            )
        }
        try container.encode(decimalValue)
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
