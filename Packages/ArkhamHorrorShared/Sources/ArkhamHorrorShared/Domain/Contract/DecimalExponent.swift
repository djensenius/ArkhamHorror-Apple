import Foundation

/// An arbitrary-precision signed base-10 exponent.
///
/// `JSONNumber.exponent` is stored using this type rather than a fixed-width `Int` so that
/// no parse, canonicalization, or comparison step can silently wrap or trap for
/// astronomically large exponents. A fixed-width `Int` cannot even represent
/// `1e9223372036854775807` (`Int64.max` itself, let alone one past it), and — critically —
/// arithmetic *on* a legitimately Int64-range-boundary exponent (subtracting a fractional
/// digit count while parsing, or adding one while trimming a canonical trailing zero) can
/// overflow even when the exponent itself was representable. `DecimalExponent` never
/// converts through a fixed-width integer internally: like `JSONNumber.coefficient`, its
/// magnitude is an unbounded run of decimal digits, so every operation this type actually
/// performs (parsing raw digit bytes, adding/subtracting a small `Int` delta) is exact
/// grade-school digit arithmetic that cannot overflow no matter how large the exponent
/// already is.
struct DecimalExponent: Sendable, Hashable {
    enum Sign: Sendable, Hashable {
        case plus
        case minus
    }

    /// The exponent's sign. Always `.plus` when `magnitude == "0"` (there is only one zero
    /// exponent, regardless of how it was spelled or computed).
    let sign: Sign
    /// Nonempty run of ASCII decimal digits, most-significant-first. Canonical: never has a
    /// leading zero unless it is exactly `"0"`.
    let magnitude: String

    static let zero = DecimalExponent(sign: .plus, magnitude: "0")

    private init(sign: Sign, magnitude: String) {
        self.sign = magnitude == "0" ? .plus : sign
        self.magnitude = magnitude
    }

    /// Constructs from a fixed-width `Int`, which is always exactly representable.
    init(_ value: Int) {
        self.init(sign: value < 0 ? .minus : .plus, magnitude: String(value.magnitude))
    }

    /// Parses a raw, possibly-huge run of ASCII digit bytes exactly as produced by the
    /// number-grammar scanner's exponent-part parsing (`parseExponentPart`), paired with a
    /// separately-parsed sign. Never fails and never overflows regardless of how many
    /// digits are present — unlike parsing into a fixed-width `Int`, there is no ceiling on
    /// how many digits this can hold.
    init(sign: Sign, digits: some Collection<UInt8>) {
        var trimmed = Substring(decoding: digits, as: UTF8.self)
        while trimmed.count > 1, trimmed.first == "0" {
            trimmed.removeFirst()
        }
        self.init(sign: sign, magnitude: String(trimmed))
    }

    var isZero: Bool {
        magnitude == "0"
    }

    /// `self + delta`, where `delta` is an ordinary fixed-width `Int` (used for the small,
    /// input-size-bounded adjustments callers actually need: subtracting a fractional digit
    /// count while parsing, or adding `1` per trimmed trailing zero while canonicalizing).
    /// Implemented as exact digit-string arithmetic, so it can never overflow regardless of
    /// how large `self` already is.
    func adding(_ delta: Int) -> DecimalExponent {
        let deltaSign: Sign = delta < 0 ? .minus : .plus
        let deltaMagnitude = String(delta.magnitude)
        if isZero {
            return DecimalExponent(sign: deltaSign, magnitude: deltaMagnitude)
        }
        if sign == deltaSign {
            return DecimalExponent(
                sign: sign, magnitude: Self.addMagnitudes(magnitude, deltaMagnitude)
            )
        }
        switch Self.compareMagnitudes(magnitude, deltaMagnitude) {
        case .orderedSame:
            return .zero
        case .orderedDescending:
            return DecimalExponent(
                sign: sign, magnitude: Self.subtractMagnitudes(magnitude, deltaMagnitude)
            )
        case .orderedAscending:
            return DecimalExponent(
                sign: deltaSign, magnitude: Self.subtractMagnitudes(deltaMagnitude, magnitude)
            )
        }
    }

    /// This exponent as an `Int`, if (and only if) it fits exactly; `nil` otherwise. Every
    /// fixed-width expansion/conversion (`plainDecimalString`, `wholeNumberMagnitude`) must
    /// check this *before* attempting to allocate, rather than trying and trapping.
    var asInt: Int? {
        switch sign {
        case .plus:
            let exceedsInt64Max = Self.compareMagnitudes(
                magnitude, Self.int64MaxMagnitude
            ) == .orderedDescending
            guard !exceedsInt64Max else { return nil }
            return Int(magnitude)
        case .minus:
            if magnitude == Self.int64MinMagnitude {
                return Int.min
            }
            let exceedsInt64Max = Self.compareMagnitudes(
                magnitude, Self.int64MaxMagnitude
            ) == .orderedDescending
            guard !exceedsInt64Max else { return nil }
            guard let value = Int(magnitude) else { return nil }
            return -value
        }
    }

    private static let int64MaxMagnitude = String(Int64.max)
    private static let int64MinMagnitude = String(Int64.min.magnitude)

    // MARK: - Unsigned decimal-digit-string arithmetic

    private static func compareMagnitudes(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.count != rhs.count {
            return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
        }
        if lhs == rhs {
            return .orderedSame
        }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func addMagnitudes(_ lhs: String, _ rhs: String) -> String {
        let leftDigits = Array(lhs.utf8.reversed())
        let rightDigits = Array(rhs.utf8.reversed())
        var result: [UInt8] = []
        var carry = 0
        for index in 0 ..< max(leftDigits.count, rightDigits.count) {
            let left = index < leftDigits.count ? Int(leftDigits[index] - 0x30) : 0
            let right = index < rightDigits.count ? Int(rightDigits[index] - 0x30) : 0
            let sum = left + right + carry
            result.append(UInt8(sum % 10) + 0x30)
            carry = sum / 10
        }
        if carry > 0 {
            result.append(UInt8(carry) + 0x30)
        }
        return Self.digitString(from: result.reversed())
    }

    /// Precondition: `lhs` (as an unsigned magnitude) is `>= rhs`.
    private static func subtractMagnitudes(_ lhs: String, _ rhs: String) -> String {
        let leftDigits = Array(lhs.utf8.reversed())
        let rightDigits = Array(rhs.utf8.reversed())
        var result: [UInt8] = []
        var borrow = 0
        for index in 0 ..< leftDigits.count {
            let left = Int(leftDigits[index] - 0x30)
            let right = index < rightDigits.count ? Int(rightDigits[index] - 0x30) : 0
            var difference = left - right - borrow
            if difference < 0 {
                difference += 10
                borrow = 1
            } else {
                borrow = 0
            }
            result.append(UInt8(difference) + 0x30)
        }
        while result.count > 1, result.last == 0x30 {
            result.removeLast()
        }
        return Self.digitString(from: result.reversed())
    }

    /// Builds a `String` directly from a sequence of ASCII digit bytes (`0x30`...`0x39`)
    /// this type's own arithmetic produced, one `UnicodeScalar` at a time. Every `UInt8`
    /// maps to a valid `UnicodeScalar` unconditionally (values 0...255 are always valid
    /// Latin-1/Basic Latin scalars), so — unlike routing through `String(bytes:encoding:)`
    /// or `String(decoding:as:)` — this can neither fail nor silently substitute anything,
    /// and never needs to consider what "invalid UTF-8" would even mean for bytes that are
    /// never anything but ASCII digits by construction.
    private static func digitString(from bytes: some Sequence<UInt8>) -> String {
        String(String.UnicodeScalarView(bytes.map(UnicodeScalar.init)))
    }
}

extension DecimalExponent: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self.init(value)
    }
}

extension DecimalExponent: CustomStringConvertible {
    /// A compact spelling (no leading `+`, and only as many digits as the exponent itself
    /// has) suitable for scientific-notation serialization — unlike expanding this exponent
    /// into literal padding zeros, this is always exactly as long as `magnitude` itself,
    /// however large that is.
    var description: String {
        sign == .minus ? "-\(magnitude)" : magnitude
    }
}
