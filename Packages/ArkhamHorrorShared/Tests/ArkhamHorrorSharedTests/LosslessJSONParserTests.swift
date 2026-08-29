@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for `LosslessJSONParser`'s explicit rejection policy for malformed input:
/// invalid UTF-8, unpaired UTF-16 surrogate escapes, trailing tokens after the root value,
/// and duplicate object keys are all parse errors, not silently accepted/normalized input.
@Suite("LosslessJSONParser")
struct LosslessJSONParserTests {
    // MARK: - Invalid UTF-8

    @Test("A document containing an invalid UTF-8 byte sequence is rejected")
    func invalidUTF8Rejected() {
        // 0xFF is not a valid UTF-8 lead byte anywhere.
        let invalid = Data([0x22, 0xFF, 0x22])
        #expect(throws: LosslessJSONParserError.invalidUTF8) {
            try LosslessJSONParser.parse(invalid)
        }
    }

    // MARK: - Unpaired surrogates

    @Test("A lone high surrogate escape with no following low surrogate is rejected")
    func loneHighSurrogateRejected() {
        let json = #""\uD800""#
        #expect(throws: LosslessJSONParserError.unpairedSurrogate) {
            try LosslessJSONParser.parse(Data(json.utf8))
        }
    }

    @Test("A high surrogate followed by a non-surrogate escape is rejected")
    func highSurrogateFollowedByNonSurrogateRejected() {
        let json = #""\uD800\u0041""#
        #expect(throws: LosslessJSONParserError.unpairedSurrogate) {
            try LosslessJSONParser.parse(Data(json.utf8))
        }
    }

    @Test("A lone low surrogate escape is rejected")
    func loneLowSurrogateRejected() {
        let json = #""\uDC00""#
        #expect(throws: LosslessJSONParserError.unpairedSurrogate) {
            try LosslessJSONParser.parse(Data(json.utf8))
        }
    }

    @Test("A valid surrogate pair decodes to its combined astral scalar")
    func validSurrogatePairDecodes() throws {
        // U+1F600 GRINNING FACE, encoded as the surrogate pair \uD83D\uDE00.
        let json = #""\uD83D\uDE00""#
        let value = try LosslessJSONParser.parse(Data(json.utf8))
        #expect(value == .string("\u{1F600}"))
    }

    // MARK: - Trailing tokens

    @Test("Trailing non-whitespace data after the root value is rejected")
    func trailingDataRejected() {
        #expect(throws: LosslessJSONParserError.trailingData(atPosition: 2)) {
            try LosslessJSONParser.parse(Data("1 2".utf8))
        }
    }

    @Test("Trailing whitespace after the root value is accepted")
    func trailingWhitespaceAccepted() throws {
        let value = try LosslessJSONParser.parse(Data("1  \n\t".utf8))
        #expect(value == .number(.integer(1)))
    }

    // MARK: - Duplicate object keys

    @Test("A duplicate object key is rejected")
    func duplicateObjectKeyRejected() {
        let json = #"{"a": 1, "a": 2}"#
        #expect(throws: LosslessJSONParserError.duplicateObjectKey("a")) {
            try LosslessJSONParser.parse(Data(json.utf8))
        }
    }

    @Test("Distinct object keys are accepted")
    func distinctObjectKeysAccepted() throws {
        let json = #"{"a": 1, "b": 2}"#
        let value = try LosslessJSONParser.parse(Data(json.utf8))
        #expect(value == .object(["a": .number(.integer(1)), "b": .number(.integer(2))]))
    }

    // MARK: - Number grammar

    @Test("A leading-zero integer part is rejected as invalidNumber, not as trailing data")
    func leadingZeroIntegerRejected() {
        // Asserting only `throws: LosslessJSONParserError.self` would also pass if the
        // scanner accepted the lone "0" and left "1" to be reported as unrelated
        // `.trailingData` by the top-level parser — a different, less accurate failure
        // mode for what RFC 8259 defines as an illegal numeral. Pin the exact case so a
        // regression to that weaker behavior fails this test.
        #expect(throws: LosslessJSONParserError.invalidNumber) {
            try LosslessJSONParser.parse(Data("01".utf8))
        }
        #expect(throws: LosslessJSONParserError.invalidNumber) {
            try LosslessJSONParser.parse(Data("-01".utf8))
        }
        #expect(throws: LosslessJSONParserError.invalidNumber) {
            try LosslessJSONParser.parse(Data("00".utf8))
        }
        // A lone "0" (optionally negative, optionally with a fractional/exponent part
        // that legally follows a "0" integer part) remains valid.
        #expect(throws: Never.self) {
            try LosslessJSONParser.parse(Data("0".utf8))
        }
        #expect(throws: Never.self) {
            try LosslessJSONParser.parse(Data("-0".utf8))
        }
        #expect(throws: Never.self) {
            try LosslessJSONParser.parse(Data("0.5".utf8))
        }
    }

    @Test("A leading '+' sign is rejected")
    func leadingPlusSignRejected() {
        #expect(throws: LosslessJSONParserError.self) {
            try LosslessJSONParser.parse(Data("+1".utf8))
        }
    }

    @Test("A bare decimal point with no digits is rejected")
    func bareDecimalPointRejected() {
        #expect(throws: LosslessJSONParserError.self) {
            try LosslessJSONParser.parse(Data("1.".utf8))
        }
    }

    @Test("An exponent with no digits is rejected")
    func emptyExponentRejected() {
        #expect(throws: LosslessJSONParserError.self) {
            try LosslessJSONParser.parse(Data("1e".utf8))
        }
    }

    // MARK: - Structural sanity

    @Test("Empty input is rejected")
    func emptyInputRejected() {
        #expect(throws: LosslessJSONParserError.unexpectedEndOfInput) {
            try LosslessJSONParser.parse(Data())
        }
    }

    @Test("An object cut off before its first key reports end-of-input, not byte 0")
    func objectTruncatedBeforeFirstKeyReportsEndOfInput() {
        #expect(throws: LosslessJSONParserError.unexpectedEndOfInput) {
            try LosslessJSONParser.parse(Data("{".utf8))
        }
    }

    @Test("An object cut off after a comma, before the next key, reports end-of-input")
    func objectTruncatedAfterCommaReportsEndOfInput() {
        #expect(throws: LosslessJSONParserError.unexpectedEndOfInput) {
            try LosslessJSONParser.parse(Data(#"{"a": 1,"#.utf8))
        }
    }

    @Test("An object with a non-quote, non-EOF byte where a key is expected reports that byte")
    func objectWithWrongKeyByteReportsUnexpectedByte() {
        #expect(throws: LosslessJSONParserError.self) {
            try LosslessJSONParser.parse(Data("{1: 2}".utf8))
        }
        // Specifically must NOT be misreported as end-of-input.
        do {
            _ = try LosslessJSONParser.parse(Data("{1: 2}".utf8))
            Issue.record("Expected parse to throw")
        } catch let LosslessJSONParserError.unexpectedByte(byte, _) {
            #expect(byte == UInt8(ascii: "1"))
        } catch {
            Issue.record("Expected .unexpectedByte, got \(error)")
        }
    }

    @Test("Empty object and empty array both parse")
    func emptyContainersParse() throws {
        #expect(try LosslessJSONParser.parse(Data("{}".utf8)) == .object([:]))
        #expect(try LosslessJSONParser.parse(Data("[]".utf8)) == .array([]))
    }

    @Test("A nested structure parses into the matching JSONValue tree")
    func nestedStructureParses() throws {
        let json = #"{"a": [1, "x", null, true, false, {"b": 2.5}]}"#
        let value = try LosslessJSONParser.parse(Data(json.utf8))
        #expect(
            try value == .object([
                "a": .array([
                    .number(.integer(1)),
                    .string("x"),
                    .null,
                    .bool(true),
                    .bool(false),
                    .object(["b": .number(JSONNumber.decimal(2.5))]),
                ]),
            ])
        )
    }

    @Test("String escape sequences decode to their literal characters")
    func stringEscapesDecode() throws {
        let json = #""a\"b\\c\/d\be\ff\ng\rh\ti""#
        let value = try LosslessJSONParser.parse(Data(json.utf8))
        #expect(value == .string("a\"b\\c/d\u{08}e\u{0C}f\ng\rh\ti"))
    }
}
