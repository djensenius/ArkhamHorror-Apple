import Foundation

/// The byte-level cursor and grammar rules `LosslessJSONParser.parse(_:)` drives. Kept in
/// its own file (and as an internal, not file-private, type) purely to stay under
/// SwiftLint's type-length limit for `LosslessJSONParser` itself.
struct LosslessJSONByteScanner {
    let bytes: [UInt8]
    var position = 0

    var isAtEnd: Bool {
        position >= bytes.count
    }

    func peek() -> UInt8? {
        isAtEnd ? nil : bytes[position]
    }

    mutating func advance() -> UInt8? {
        guard !isAtEnd else { return nil }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func expect(_ byte: UInt8) throws {
        guard let found = advance() else { throw LosslessJSONParserError.unexpectedEndOfInput }
        guard found == byte else {
            throw LosslessJSONParserError.unexpectedByte(found, atPosition: position - 1)
        }
    }

    mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            position += 1
        }
    }

    mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard let byte = peek() else { throw LosslessJSONParserError.unexpectedEndOfInput }
        switch byte {
        case 0x7B: return try parseObject()
        case 0x5B: return try parseArray()
        case 0x22: return try .string(parseString())
        case 0x74: try expectLiteral("true"); return .bool(true)
        case 0x66: try expectLiteral("false"); return .bool(false)
        case 0x6E: try expectLiteral("null"); return .null
        case 0x2D, 0x30 ... 0x39: return try .number(parseNumber())
        default: throw LosslessJSONParserError.unexpectedByte(byte, atPosition: position)
        }
    }

    mutating func expectLiteral(_ text: String) throws {
        for expected in text.utf8 {
            guard advance() == expected else { throw LosslessJSONParserError.invalidLiteral }
        }
    }

    /// Consumes a comma (meaning another element follows) or `closingByte` (meaning the
    /// container ends here), throwing otherwise. Shared by `parseObject`/`parseArray` to
    /// keep both simple.
    private mutating func consumeElementSeparator(closingByte: UInt8) throws -> Bool {
        guard let next = advance() else { throw LosslessJSONParserError.unexpectedEndOfInput }
        if next == 0x2C {
            return true
        }
        if next == closingByte {
            return false
        }
        throw LosslessJSONParserError.unexpectedByte(next, atPosition: position - 1)
    }

    mutating func parseObject() throws -> JSONValue {
        position += 1 // consume '{'
        var result: [String: JSONValue] = [:]
        var seenKeys: Set<String> = []
        skipWhitespace()
        if peek() == 0x7D {
            position += 1
            return .object(result)
        }
        while true {
            skipWhitespace()
            guard let keyStartByte = peek() else {
                throw LosslessJSONParserError.unexpectedEndOfInput
            }
            guard keyStartByte == 0x22 else {
                throw LosslessJSONParserError.unexpectedByte(keyStartByte, atPosition: position)
            }
            let key = try parseString()
            guard seenKeys.insert(key).inserted else {
                throw LosslessJSONParserError.duplicateObjectKey(key)
            }
            skipWhitespace()
            try expect(0x3A) // ':'
            result[key] = try parseValue()
            skipWhitespace()
            guard try consumeElementSeparator(closingByte: 0x7D) else { break }
        }
        return .object(result)
    }

    mutating func parseArray() throws -> JSONValue {
        position += 1 // consume '['
        var result: [JSONValue] = []
        skipWhitespace()
        if peek() == 0x5D {
            position += 1
            return .array(result)
        }
        while true {
            try result.append(parseValue())
            skipWhitespace()
            guard try consumeElementSeparator(closingByte: 0x5D) else { break }
        }
        return .array(result)
    }

    mutating func parseString() throws -> String {
        try expect(0x22) // opening quote
        var buffer: [UInt8] = []
        while true {
            guard let byte = advance() else { throw LosslessJSONParserError.unexpectedEndOfInput }
            if byte == 0x22 {
                break
            }
            if byte == 0x5C {
                try appendEscape(to: &buffer)
            } else if byte < 0x20 {
                // RFC 8259 forbids unescaped control characters inside strings.
                throw LosslessJSONParserError.unexpectedByte(byte, atPosition: position - 1)
            } else {
                buffer.append(byte)
            }
        }
        guard let result = String(bytes: buffer, encoding: .utf8) else {
            throw LosslessJSONParserError.invalidUTF8
        }
        return result
    }

    /// Single-byte escapes (`\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t`) mapped from
    /// their escape-letter byte to the literal byte they produce. `\u` is handled
    /// separately by ``appendEscape(to:)`` since it is not a fixed 1-byte substitution.
    private static let singleByteEscapes: [UInt8: UInt8] = [
        0x22: 0x22, 0x5C: 0x5C, 0x2F: 0x2F, 0x62: 0x08,
        0x66: 0x0C, 0x6E: 0x0A, 0x72: 0x0D, 0x74: 0x09,
    ]

    mutating func appendEscape(to buffer: inout [UInt8]) throws {
        guard let escape = advance() else { throw LosslessJSONParserError.unexpectedEndOfInput }
        if let literal = Self.singleByteEscapes[escape] {
            buffer.append(literal)
            return
        }
        guard escape == 0x75 else { throw LosslessJSONParserError.invalidEscape } // \u
        let scalar = try parseUnicodeEscape()
        buffer.append(contentsOf: Array(String(scalar).utf8))
    }

    mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let firstUnit = try parseHex4()
        if (0xD800 ... 0xDBFF).contains(firstUnit) {
            return try parseLowSurrogate(afterHighSurrogate: firstUnit)
        }
        if (0xDC00 ... 0xDFFF).contains(firstUnit) {
            throw LosslessJSONParserError.unpairedSurrogate
        }
        guard let scalar = Unicode.Scalar(firstUnit) else {
            throw LosslessJSONParserError.unpairedSurrogate
        }
        return scalar
    }

    /// Consumes the `\uDCxx`-`\uDFFFx` low-surrogate escape a `highSurrogate` requires to
    /// combine into one scalar beyond the Basic Multilingual Plane, throwing if the
    /// following escape is missing or is not itself a valid low surrogate.
    private mutating func parseLowSurrogate(
        afterHighSurrogate highSurrogate: UInt32
    ) throws -> Unicode.Scalar {
        guard advance() == 0x5C, advance() == 0x75 else {
            throw LosslessJSONParserError.unpairedSurrogate
        }
        let lowSurrogate = try parseHex4()
        guard (0xDC00 ... 0xDFFF).contains(lowSurrogate) else {
            throw LosslessJSONParserError.unpairedSurrogate
        }
        let combined = 0x10000 + (highSurrogate - 0xD800) * 0x400 + (lowSurrogate - 0xDC00)
        guard let scalar = Unicode.Scalar(combined) else {
            throw LosslessJSONParserError.unpairedSurrogate
        }
        return scalar
    }

    mutating func parseHex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0 ..< 4 {
            guard let byte = advance(), let digit = Self.hexDigitValue(byte) else {
                throw LosslessJSONParserError.invalidUnicodeEscape
            }
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    static func hexDigitValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30 ... 0x39: byte - 0x30
        case 0x41 ... 0x46: byte - 0x41 + 10
        case 0x61 ... 0x66: byte - 0x61 + 10
        default: nil
        }
    }
}

extension String {
    /// A `String(bytes:encoding:)`-based conversion (never `String(decoding:as:)`, which
    /// silently substitutes invalid sequences instead of failing) for the ASCII
    /// digit/sign/exponent byte spans `parseNumber` slices out of an already
    /// UTF-8-validated document.
    init?(safelyDecoding bytes: some Collection<UInt8>) {
        self.init(bytes: bytes, encoding: .utf8)
    }
}

extension Int {
    init?(safelyDecoding bytes: some Collection<UInt8>) {
        guard let text = String(safelyDecoding: bytes) else { return nil }
        self.init(text)
    }
}
