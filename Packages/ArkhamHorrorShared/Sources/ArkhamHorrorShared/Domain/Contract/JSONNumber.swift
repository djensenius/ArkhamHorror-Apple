import Foundation

/// A finite, arbitrary-precision JSON number: `sign * coefficient * 10^exponent`.
///
/// Backend identifiers and numeric literals may exceed what any of Foundation's
/// fixed-precision numeric types can hold exactly: `Double` loses bits beyond a 53-bit
/// mantissa, `Decimal` rounds beyond roughly 38 significant digits and cannot represent an
/// exponent much past +/-128, and `Int64` overflows past ~19 digits. This type never
/// converts a parsed numeral through any of them for storage — `coefficient` is an
/// unbounded string of decimal digits, so a literal like
/// `1.000000000000000000000000000000000000001` or `1e128` round-trips exactly.
///
/// There is no representation for NaN or infinity: every value this type can hold is
/// finite by construction, and every initializer that could receive a nonfinite input
/// (``decimal(_:)``, ``init(double:)``) validates and throws rather than silently
/// constructing something that later encodes as invalid JSON.
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

    /// The number's sign. Distinguishes `-0` from `0` for round-trip fidelity, even though
    /// the two compare equal (see ``==(_:_:)``).
    let sign: Sign
    /// Decimal digits only (`0`-`9`), most-significant first. Canonical: never empty, and
    /// never has a leading `0` unless the entire coefficient is the single digit `"0"`.
    let coefficient: String
    /// Base-10 exponent: the number's exact value is `sign * coefficient * 10^exponent`.
    let exponent: Int
    /// The exact original JSON numeral text, when this value was produced by
    /// ``LosslessJSONParser``. `nil` for programmatically constructed values.
    /// ``LosslessJSONEncoder`` reproduces this token byte-for-byte when present.
    let rawToken: String?

    private init(uncheckedSign sign: Sign, coefficient: String, exponent: Int, rawToken: String?) {
        self.sign = sign
        self.coefficient = coefficient
        self.exponent = exponent
        self.rawToken = rawToken
    }

    /// Validates and constructs a number from explicit components. `coefficient` must be a
    /// nonempty run of ASCII digits with no leading zero (unless it is exactly `"0"`).
    init(sign: Sign = .plus, coefficient: String, exponent: Int, rawToken: String? = nil) throws {
        guard !coefficient.isEmpty else { throw ValidationError.emptyCoefficient }
        guard coefficient.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }) else {
            throw ValidationError.nonDigitCoefficient
        }
        guard coefficient == "0" || coefficient.first != "0" else {
            throw ValidationError.leadingZeroCoefficient
        }
        self.init(
            uncheckedSign: sign,
            coefficient: coefficient,
            exponent: exponent,
            rawToken: rawToken
        )
    }

    /// Parses a plain decimal numeral (optional leading `-`, digits, optional `.` + digits;
    /// no exponent letter) such as `Decimal`'s own `description` always produces.
    fileprivate init(exactPlainDecimalString text: String) throws {
        var remaining = Substring(text)
        var sign: Sign = .plus
        if remaining.first == "-" {
            sign = .minus
            remaining.removeFirst()
        }
        let parts = remaining.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else {
            throw ValidationError.nonDigitCoefficient
        }
        let intPart = parts[0]
        let fracPart = parts.count == 2 ? parts[1] : Substring()
        guard !intPart.isEmpty, intPart.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }) else {
            throw ValidationError.nonDigitCoefficient
        }
        guard fracPart.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }) else {
            throw ValidationError.nonDigitCoefficient
        }
        var digits = Array(intPart) + Array(fracPart)
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
        }
        self.init(
            uncheckedSign: sign,
            coefficient: String(digits),
            exponent: -fracPart.count,
            rawToken: nil
        )
    }

    /// Constructs an exact number from a finite `Double`. Throws for `.nan` and
    /// `.infinity`/`-.infinity` rather than silently constructing a value that cannot be
    /// re-encoded as valid JSON.
    init(double value: Double) throws {
        guard value.isFinite else { throw ValidationError.nonfiniteValue }
        // `Double`'s own shortest round-tripping description is exact for that `Double`
        // (it is not exact for the *original decimal literal* someone may have typed, but
        // it is exact for the `Double` value actually held).
        try self.init(exactPlainDecimalString: shortestPlainDecimal(for: value))
    }

    /// An exact whole-number value. `Int64` is always finite, so this cannot fail.
    static func integer(_ value: Int64) -> JSONNumber {
        let sign: Sign = value < 0 ? .minus : .plus
        // `Int64.min.magnitude` does not fit in `Int64`, so go through `UInt64` first.
        let magnitude = value.magnitude
        return JSONNumber(
            uncheckedSign: sign,
            coefficient: String(magnitude),
            exponent: 0,
            rawToken: nil
        )
    }

    /// An exact value from a finite `Decimal`. Throws for `Decimal.nan`.
    static func decimal(_ value: Decimal) throws -> JSONNumber {
        guard !value.isNaN else { throw ValidationError.nonfiniteValue }
        return try JSONNumber(exactPlainDecimalString: "\(value)")
    }

    /// This value rendered as plain decimal digits (no exponent letter), expanding the
    /// exponent into literal trailing zeros or a decimal point. Used by the standard
    /// `Encoder` fallback path (see ``encode(to:)``) and by ``LosslessJSONEncoder`` when no
    /// ``rawToken`` is available.
    var plainDecimalString: String {
        let signPrefix = sign == .minus ? "-" : ""
        if exponent >= 0 {
            return signPrefix + coefficient + String(repeating: "0", count: exponent)
        }
        let fractionDigits = -exponent
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
        JSONNumber(uncheckedSign: .plus, coefficient: String(value), exponent: 0, rawToken: nil)
    }

    /// This value's exact digits as an unsigned whole number (for example `100`, `1e2`, and
    /// `1.00` all yield `"100"`/`"1"`/`"100"` respectively), if it represents an integer
    /// with no nonzero fractional remainder. `nil` for values like `1.5` that are not
    /// whole numbers.
    var wholeNumberMagnitude: String? {
        if exponent >= 0 {
            return coefficient + String(repeating: "0", count: exponent)
        }
        let fractionDigits = -exponent
        guard fractionDigits < coefficient.count else {
            let allZero = coefficient.allSatisfy { $0 == "0" }
            return allZero ? "0" : nil
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
        let exponent: Int
    }

    private var canonicalTriple: CanonicalTriple {
        if coefficient.allSatisfy({ $0 == "0" }) {
            return CanonicalTriple(sign: .plus, coefficient: "0", exponent: 0)
        }
        var digits = Array(coefficient)
        var exp = exponent
        while digits.count > 1, digits.last == "0" {
            digits.removeLast()
            exp += 1
        }
        return CanonicalTriple(sign: sign, coefficient: String(digits), exponent: exp)
    }

    /// Attempts an exact (never rounded) `Decimal` reconstruction, verified by re-parsing
    /// the resulting `Decimal`'s own description and confirming it is canonically equal to
    /// `self`. `nil` when `Decimal` cannot represent this value exactly.
    private var asExactDecimal: Decimal? {
        let locale = Locale(identifier: "en_US")
        guard let value = Decimal(string: plainDecimalString, locale: locale) else {
            return nil
        }
        guard let roundTripped = try? JSONNumber(exactPlainDecimalString: "\(value)") else {
            return nil
        }
        return roundTripped.canonicalTriple == canonicalTriple ? value : nil
    }
}

/// `Double`'s shortest round-tripping plain-decimal description (no exponent letter).
private func shortestPlainDecimal(for value: Double) -> String {
    // `"\(value)"` uses exponent notation for very large/small magnitudes; `String(format:)`
    // is unsuitable (fixed precision). Foundation's `Decimal(value)` conversion from a
    // `BinaryFloatingPoint` is exact for the `Double` it is given and never uses exponent
    // notation in its own description, so route through it purely for formatting.
    "\(Decimal(value))"
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
        if exponent == 0, let intValue = Int64(sign == .minus ? "-\(coefficient)" : coefficient) {
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
    var description: String {
        rawToken ?? plainDecimalString
    }
}
