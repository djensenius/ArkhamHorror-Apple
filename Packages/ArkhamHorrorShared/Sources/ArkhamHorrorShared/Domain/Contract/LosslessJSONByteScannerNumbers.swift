import Foundation

/// `LosslessJSONByteScanner`'s number-grammar helpers (RFC 8259 integer/fractional/exponent
/// parts). Split into its own file purely to stay under SwiftLint's type-body-length limit
/// for the main scanner struct.
extension LosslessJSONByteScanner {
    // MARK: - Numbers

    /// Consumes a run of ASCII digit bytes starting at the current position and returns
    /// the consumed slice (possibly empty).
    mutating func consumeDigitRun() -> ArraySlice<UInt8> {
        let start = position
        while let byte = peek(), (0x30 ... 0x39).contains(byte) {
            position += 1
        }
        return bytes[start ..< position]
    }

    /// The integer part per RFC 8259: either a lone `"0"`, or a nonzero digit followed by
    /// any further digits. A leading zero followed by more digits (`"01"`) is illegal.
    mutating func parseIntegerPart() throws -> ArraySlice<UInt8> {
        guard let firstDigit = peek(), (0x30 ... 0x39).contains(firstDigit) else {
            throw LosslessJSONParserError.invalidNumber
        }
        let start = position
        if firstDigit == 0x30 {
            position += 1 // a lone "0"; no further integer-part digits are legal
            return bytes[start ..< position]
        }
        return consumeDigitRun()
    }

    /// The optional `.digits` fractional part. Returns an empty slice when absent; throws
    /// if a `.` is present with no digits following it.
    mutating func parseFractionalPart() throws -> ArraySlice<UInt8> {
        guard peek() == 0x2E else { return bytes[position ..< position] }
        position += 1
        guard let byte = peek(), (0x30 ... 0x39).contains(byte) else {
            throw LosslessJSONParserError.invalidNumber
        }
        return consumeDigitRun()
    }

    /// The optional `e`/`E[+-]digits` exponent part. Returns `.zero` when absent; throws if
    /// an `e`/`E` is present with no digits following the optional sign.
    ///
    /// The digit run is parsed directly into a ``DecimalExponent`` rather than through a
    /// fixed-width `Int`: unlike `Int(safelyDecoding:)`, which fails (or, worse, could wrap)
    /// once the exponent's own digit count exceeds what `Int64` can hold, `DecimalExponent`
    /// has no ceiling on how many digits it can represent, so an exponent this large
    /// (`1e9223372036854775807` and beyond) is parsed exactly rather than rejected or
    /// mis-parsed.
    mutating func parseExponentPart() throws -> DecimalExponent {
        guard let byte = peek(), byte == 0x65 || byte == 0x45 else { return .zero }
        position += 1
        var expSign: DecimalExponent.Sign = .plus
        if let signByte = peek(), signByte == 0x2B || signByte == 0x2D {
            if signByte == 0x2D {
                expSign = .minus
            }
            position += 1
        }
        guard let byte = peek(), (0x30 ... 0x39).contains(byte) else {
            throw LosslessJSONParserError.invalidNumber
        }
        let digits = consumeDigitRun()
        return DecimalExponent(sign: expSign, digits: digits)
    }

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
