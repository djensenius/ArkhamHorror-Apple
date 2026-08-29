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
    /// `fileprivate`, not merely documented-as-internal: this is the one seam in the
    /// entire type that pairs a `rawToken` string with separately-supplied components
    /// without re-validating them against each other — exactly the seam that must never
    /// be reachable outside this exact file, since ``LosslessJSONSerializer`` writes
    /// `rawToken` back out completely unescaped, and a caller-supplied (rather than
    /// scanner-derived) `rawToken` could smuggle arbitrary trailing JSON structure
    /// (`1,"injected":true`) straight into a parent object or array. Its only caller,
    /// `LosslessJSONByteScanner.parseNumber()` below, is deliberately colocated in this
    /// same file so the language itself — not a comment — makes that the case: `fileprivate`
    /// is inaccessible from every other file in this module, including via `@testable
    /// import` from test targets, so no amount of module-internal (or test) code anywhere
    /// else can construct this pairing. `parseNumber()` is safe because it builds
    /// `coefficient` from the exact same digit bytes as `rawToken`'s span, so the two can
    /// never disagree.
    fileprivate static func parsed(
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

    /// An exact unsigned whole-number value (used for `UInt64` values that may exceed
    /// `Int64.max`).
    static func unsignedInteger(_ value: UInt64) -> JSONNumber {
        JSONNumber(uncheckedSign: .plus, coefficient: String(value), exponent: .zero, rawToken: nil)
    }
}

// `plainDecimalString`, `isZero`, `wholeNumberMagnitude`, `CanonicalTriple`/`canonicalTriple`,
// `asExactDecimal`, `Equatable`, `Hashable`, and `CustomStringConvertible` all live in
// `JSONNumberRepresentation.swift` — none of them need this file's private `uncheckedSign`
// initializer or `fileprivate` `parsed(...)` factory, so keeping them in a separate file
// keeps this one under SwiftLint's file-length limit without weakening any access control.

/// Implemented by a `Decoder` that can expose the exact original numeral it is currently
/// positioned at, bypassing fixed-precision conversion entirely. Only
/// ``LosslessJSONDecoder`` (used via ``ContractJSON/decode(_:from:)``) conforms; a stock
/// `Decoder` (for example Foundation's `JSONDecoder`) does not, so ``JSONNumber``'s
/// `Decodable` conformance below falls back to a narrow, provably-exact-or-throw
/// reconstruction in that case — never a silent best-effort rounding — succeeding only for
/// values a fixed-precision Foundation type can decode without loss, and throwing
/// otherwise (see that conformance's own documentation for the exact gate and its one
/// documented residual limitation).
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
        // digit sequence and therefore can never be a *canonical* decode path for this
        // type — only `ContractJSON.decode` (backed by `LosslessJSONNumberSource`) is.
        // This never routes through `Decimal` as the *stored* value (no `Decimal`
        // best-effort fallback survives here at all): the only conversions permitted are
        // ones a fixed-precision Foundation type decode can succeed at, gated by an
        // independent `Decimal`-based fractionality check so that a "successful" `Int64`/
        // `UInt64` decode is never blindly trusted on its own.
        //
        // That gate matters because `Int64`/`UInt64` decode success is *not*, by itself,
        // reliable proof of exactness: Foundation's fixed-width integer decoding silently
        // rounds some extreme-precision fractional literals that happen to be numerically
        // indistinguishable, at `Double` precision, from a nearby whole number (for
        // example a "1" followed by dozens of zeros and a trailing "1" decodes as
        // `Int64(1)`, even though the JSON text plainly has a decimal point). `Decimal`
        // preserves roughly 38 significant decimal digits — several times `Double`'s ~17
        // — so decoding as `Decimal` first and requiring a non-negative `exponent` (i.e.
        // no remaining fractional digits after Decimal's own, more precise, rounding)
        // correctly rejects every such fraction *within* that budget, which blind `Int64`
        // trust does not.
        //
        // The one residual case no stock Foundation API can distinguish from a whole
        // number is a literal whose true precision exceeds even `Decimal`'s own ~38-39
        // digit budget *and* which happens to collapse to a whole number under Decimal's
        // own rounding: `Decimal(string:)` itself already collapses that value before
        // `JSONDecoder` or this initializer ever sees it, independent of any choice made
        // here. There is no stock API that exposes the original digit sequence to prove
        // otherwise — only `ContractJSON`'s parser retains it. See
        // `JSONNumberStockDecoderFallbackTests` for the exact boundary (proven directly
        // against `Decimal(string:)`, not just this initializer) and for concrete
        // realistic-precision fractions this gate does correctly reject.
        let container = try decoder.singleValueContainer()
        guard let decimalValue = try? container.decode(Decimal.self), decimalValue.exponent >= 0
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: """
                    A standard JSONDecoder cannot prove this JSON number decodes without \
                    loss (it is fractional, exceeds Decimal's representable range, or is \
                    otherwise not exactly representable). Decode through ContractJSON \
                    instead.
                    """
                )
            )
        }
        if let intValue = try? container.decode(Int64.self) {
            self = .integer(intValue)
            return
        }
        if let uintValue = try? container.decode(UInt64.self) {
            self = JSONNumber(
                uncheckedSign: .plus, coefficient: String(uintValue), exponent: .zero,
                rawToken: nil
            )
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: """
                This JSON number's magnitude exceeds what a standard JSONDecoder can \
                represent exactly (beyond UInt64's range). Decode through ContractJSON \
                instead.
                """
            )
        )
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

extension LosslessJSONByteScanner {
    /// Parses a single, complete JSON numeral (RFC 8259 integer/fractional/exponent parts,
    /// delegated to `LosslessJSONByteScannerNumbers`) starting at the current position.
    ///
    /// Deliberately defined *here*, in the same file as
    /// ``JSONNumber/parsed(sign:coefficient:exponent:rawToken:)``, rather than alongside
    /// this scanner's other grammar helpers: that factory is
    /// `fileprivate`, so its one legitimate caller must live in this same file for the
    /// language itself to make the unsafe `rawToken`-pairing seam unreachable from
    /// anywhere else in the module (see that factory's documentation).
    mutating func parseNumber() throws -> JSONNumber {
        let start = position
        var sign: JSONNumber.Sign = .plus
        if peek() == 0x2D {
            sign = .minus
            position += 1
        }
        let intDigits = try parseIntegerPart()
        let fracDigits = try parseFractionalPart()
        let explicitExponent = try parseExponentPart()

        guard let rawToken = String(safelyDecoding: bytes[start ..< position]) else {
            throw LosslessJSONParserError.invalidNumber
        }
        var digits = Array(intDigits) + Array(fracDigits)
        while digits.count > 1, digits.first == 0x30 {
            digits.removeFirst()
        }
        guard let coefficient = String(safelyDecoding: digits) else {
            throw LosslessJSONParserError.invalidNumber
        }
        // `fracDigits.count` is always small (bounded by the literal's own length in the
        // input), so this subtraction can never overflow `DecimalExponent`'s arithmetic
        // regardless of how astronomically large `explicitExponent` itself already is.
        let exponent = explicitExponent.adding(-fracDigits.count)
        // `coefficient` was built above purely from ASCII digit bytes (`0x30...0x39`), so
        // it already satisfies every invariant the validating initializer would check;
        // constructing directly here avoids both redundant re-validation and, more
        // importantly, ever routing a `rawToken` through any path that would accept one
        // paired with caller-supplied (as opposed to scanner-derived) components.
        return JSONNumber.parsed(
            sign: sign,
            coefficient: coefficient,
            exponent: exponent,
            rawToken: rawToken
        )
    }
}
