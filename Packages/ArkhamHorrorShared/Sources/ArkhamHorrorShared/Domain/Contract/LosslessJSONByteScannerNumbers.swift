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

    /// The optional `e`/`E[+-]digits` exponent part. Returns 0 when absent; throws if an
    /// `e`/`E` is present with no digits following the optional sign.
    mutating func parseExponentPart() throws -> Int {
        guard let byte = peek(), byte == 0x65 || byte == 0x45 else { return 0 }
        position += 1
        var expSign = 1
        if let signByte = peek(), signByte == 0x2B || signByte == 0x2D {
            if signByte == 0x2D {
                expSign = -1
            }
            position += 1
        }
        guard let byte = peek(), (0x30 ... 0x39).contains(byte) else {
            throw LosslessJSONParserError.invalidNumber
        }
        let digits = consumeDigitRun()
        guard let magnitude = Int(safelyDecoding: digits) else {
            throw LosslessJSONParserError.invalidNumber
        }
        return expSign * magnitude
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
        let exponent = explicitExponent - fracDigits.count
        do {
            return try JSONNumber(
                sign: sign,
                coefficient: coefficient,
                exponent: exponent,
                rawToken: rawToken
            )
        } catch {
            throw LosslessJSONParserError.invalidNumber
        }
    }
}
