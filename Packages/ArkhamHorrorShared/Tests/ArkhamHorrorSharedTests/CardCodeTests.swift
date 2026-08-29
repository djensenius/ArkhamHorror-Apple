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
}
