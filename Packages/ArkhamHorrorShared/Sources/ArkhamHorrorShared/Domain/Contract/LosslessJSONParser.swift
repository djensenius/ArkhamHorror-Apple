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
    case nestingTooDeep
    /// The document exceeds ``LosslessJSONParser/defaultMaxDocumentByteCount`` (or a
    /// caller-supplied override). Reported before any per-byte scanning, decoding, or
    /// UTF-8 validation is attempted, so an oversized document's cost to this parser is
    /// always O(1) — never proportional to its own (rejected) size.
    case documentTooLarge(byteCount: Int, limit: Int)
}

/// A hand-written, RFC 8259 JSON parser producing a ``JSONValue`` tree directly from raw
/// bytes, never through `JSONSerialization`/`JSONDecoder`. Numbers are captured with their
/// exact original digit sequence (see ``JSONNumber``); no fixed-precision numeric type is
/// ever consulted while parsing. The byte-level scanning itself lives in
/// ``LosslessJSONByteScanner``, kept in its own file to stay under SwiftLint's type-length
/// limit.
enum LosslessJSONParser {
    /// A conservative ceiling on total document size, enforced before any byte-array copy,
    /// UTF-8 validation, or scanning is attempted. This is this module's designated
    /// canonical boundary for remote/network-sourced JSON (see ``ContractJSON``): unlike
    /// nesting depth (bounded by ``LosslessJSONByteScanner/maxNestingDepth`` to protect the
    /// call stack), nothing else in this parser bounds the *flat* cost of scanning a huge
    /// number literal, string, or top-level array/object — a pathologically large document
    /// could otherwise force multiple full-size O(n) copies (the `[UInt8]` copy, the UTF-8
    /// validation `String`, the resulting `JSONValue` tree) purely from its own size, with
    /// no nesting required at all.
    ///
    /// 16 MiB was chosen for generous headroom, not tightness: it is over 1000x the largest
    /// real governed contract fixture this client vendors (`manifest.json`, ~5.7 KB; see
    /// `Fixtures/Contract`), comfortably covers a full card catalog or game list many times
    /// larger than anything the backend currently returns, and yet still keeps the total
    /// memory a single oversized/adversarial document could force this parser to allocate
    /// (across its few full-document-sized copies) at a modest, bounded multiple of 16 MiB
    /// — never proportional to an attacker-chosen, unbounded size.
    static let defaultMaxDocumentByteCount = 16 * 1024 * 1024

    /// Parses `data` as a single complete JSON document. Throws if `data` exceeds
    /// `maxByteCount`, is not valid UTF-8, does not parse as exactly one JSON value, or
    /// contains anything the explicit rejection policy above disallows.
    ///
    /// - Parameter maxByteCount: The total document size ceiling, defaulting to
    ///   ``defaultMaxDocumentByteCount``. Exposed only so tests can exercise the exact
    ///   boundary (and one byte beyond it) without allocating a 16 MiB document; production
    ///   call sites should not override this.
    static func parse(
        _ data: Data,
        maxByteCount: Int = defaultMaxDocumentByteCount
    ) throws -> JSONValue {
        guard data.count <= maxByteCount else {
            throw LosslessJSONParserError.documentTooLarge(
                byteCount: data.count, limit: maxByteCount
            )
        }
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
