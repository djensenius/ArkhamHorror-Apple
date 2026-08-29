@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("CardCode")
struct CardCodeTests {
    @Test("An official card code decodes and round-trips")
    func officialCode() throws {
        let code = try CardCode("c01020")
        #expect(code.rawValue == "c01020")
        #expect(code.description == "c01020")
    }

    @Test("A homebrew card code with colons decodes")
    func homebrewCode() throws {
        let code = try CardCode("c:dark-matter:151")
        #expect(code.rawValue == "c:dark-matter:151")
    }

    @Test(
        "Malformed codes are rejected",
        arguments: ["", "c", "01020", "C01020", "x01020"]
    )
    func rejectsMalformed(input: String) {
        #expect(throws: CardCodeError.malformed) {
            try CardCode(input)
        }
    }

    @Test("JSON decoding of a malformed code throws DecodingError, not a trap")
    func jsonDecodingMalformed() {
        let data = Data(#""01020""#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CardCode.self, from: data)
        }
    }

    @Test("JSON decoding of a wrong scalar type throws DecodingError")
    func jsonDecodingWrongType() {
        let data = Data("42".utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CardCode.self, from: data)
        }
    }

    @Test("JSON round-trip preserves the exact code")
    func jsonRoundTrip() throws {
        let code = try CardCode("c:homebrew:xyz")
        let data = try JSONEncoder().encode(code)
        #expect(String(data: data, encoding: .utf8) == #""c:homebrew:xyz""#)
        let decoded = try JSONDecoder().decode(CardCode.self, from: data)
        #expect(decoded == code)
    }

    @Test("Card codes are usable as dictionary keys")
    func hashable() throws {
        let first = try CardCode("c01020")
        let second = try CardCode("c01020")
        #expect([first: 1] == [second: 1])
    }

    // MARK: - Unicode scalar semantics (not grapheme-cluster count)

    @Test("A combining mark immediately after c is a valid one-scalar payload")
    func combiningMarkPayload() throws {
        // "c" + U+0301 COMBINING ACUTE ACCENT forms a single Swift `Character` (one
        // grapheme cluster), but is two Unicode scalars, satisfying `^c.+$` at the
        // scalar level the published pattern actually operates on.
        let input = "c\u{0301}"
        #expect(input.count == 1, "sanity check: this is one grapheme cluster")
        let code = try CardCode(input)
        #expect(code.rawValue == input)
    }

    @Test("An astral (supplementary-plane) suffix scalar is a valid payload")
    func astralSuffix() throws {
        // U+1F600 GRINNING FACE is a single Unicode scalar outside the BMP.
        let input = "c\u{1F600}"
        let code = try CardCode(input)
        #expect(code.rawValue == input)
    }

    @Test("Decomposed (NFD) Unicode is accepted and never renormalized")
    func decomposedUnicodeNotNormalized() throws {
        // "é" as "e" + combining acute accent (NFD), rather than the precomposed U+00E9.
        let input = "c" + "e\u{0301}"
        let code = try CardCode(input)
        #expect(code.rawValue == input)
        #expect(Array(code.rawValue.unicodeScalars) == Array(input.unicodeScalars))
    }

    @Test("Empty payload after c is rejected")
    func emptyPayloadAfterC() {
        #expect(throws: CardCodeError.malformed) {
            try CardCode("c")
        }
    }

    @Test("A wrong prefix is rejected")
    func wrongPrefix() {
        #expect(throws: CardCodeError.malformed) {
            try CardCode("d01020")
        }
    }

    @Test(
        "A line terminator anywhere in the payload is rejected, matching ECMAScript dot",
        arguments: ["c\n", "c\r", "c\u{2028}", "c\u{2029}", "c01\n020", "c\n01020"]
    )
    func lineTerminatorRejected(input: String) {
        #expect(throws: CardCodeError.malformed) {
            try CardCode(input)
        }
    }

    @Test("A non-line-terminator payload after a valid character is still accepted")
    func multiCharacterPayloadStillAccepted() throws {
        let code = try CardCode("c01\t020")
        #expect(code.rawValue == "c01\t020")
    }
}
