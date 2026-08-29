import Foundation

/// The explicit rejection policy for malformed input `LosslessJSONParser` enforces beyond
/// bare JSON grammar: invalid UTF-8, unpaired UTF-16 surrogate escapes, trailing tokens
/// after the root value, and duplicate object keys are all parse errors rather than
/// silently accepted/normalized input.
enum LosslessJSONParserError: Error, Equatable, Sendable {
    case invalidUTF8
    case unexpectedEndOfInput
    case unexpectedByte(UInt8, atPosition: Int)
    case trailingData(atPosition: Int)
    case duplicateObjectKey(String)
    case invalidEscape
    case invalidUnicodeEscape
    case unpairedSurrogate
    case invalidNumber
    case invalidLiteral
}

/// A hand-written, RFC 8259 JSON parser producing a ``JSONValue`` tree directly from raw
/// bytes, never through `JSONSerialization`/`JSONDecoder`. Numbers are captured with their
/// exact original digit sequence (see ``JSONNumber``); no fixed-precision numeric type is
/// ever consulted while parsing. The byte-level scanning itself lives in
/// ``LosslessJSONByteScanner``, kept in its own file to stay under SwiftLint's type-length
/// limit.
enum LosslessJSONParser {
    /// Parses `data` as a single complete JSON document. Throws if `data` is not valid
    /// UTF-8, does not parse as exactly one JSON value, or contains anything the explicit
    /// rejection policy above disallows.
    static func parse(_ data: Data) throws -> JSONValue {
        // Copy the document into a byte array exactly once, then validate UTF-8 from that
        // same array (not the original `Data`) so the parser never holds two independent
        // full copies of a potentially large document at once.
        let bytes = [UInt8](data)
        // `String(bytes:encoding:)` performs strict validation (unlike
        // `String(decoding:as:)`, which silently substitutes invalid sequences), so this is
        // sufficient to make later byte-level scanning of ASCII structural characters safe:
        // continuation/lead bytes of any multi-byte scalar are always >= 0x80, so they can
        // never be mistaken for a structural byte (all of which are ASCII).
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw LosslessJSONParserError.invalidUTF8
        }
        var scanner = LosslessJSONByteScanner(bytes: bytes)
        scanner.skipWhitespace()
        let value = try scanner.parseValue()
        scanner.skipWhitespace()
        guard scanner.isAtEnd else {
            throw LosslessJSONParserError.trailingData(atPosition: scanner.position)
        }
        return value
    }
}
