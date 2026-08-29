@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("OpenStringEnum")
struct OpenStringEnumTests {
    @Test("A known value matches its named static constant")
    func knownValueMatches() throws {
        let data = Data(#""Guardian""#.utf8)
        let decoded = try JSONDecoder().decode(ClassSymbol.self, from: data)
        #expect(decoded == .guardian)
    }

    @Test("An unrecognized future value decodes losslessly instead of failing")
    func unknownValuePreserved() throws {
        let data = Data(#""Warlock""#.utf8)
        let decoded = try JSONDecoder().decode(ClassSymbol.self, from: data)
        #expect(decoded == ClassSymbol("Warlock"))
        #expect(decoded != .guardian)
        #expect(decoded.rawValue == "Warlock")
    }

    @Test("Encoding round-trips an unknown value exactly")
    func unknownValueRoundTrips() throws {
        let value = ClassSymbol("Warlock")
        let data = try JSONEncoder().encode(value)
        #expect(String(data: data, encoding: .utf8) == #""Warlock""#)
        let decoded = try JSONDecoder().decode(ClassSymbol.self, from: data)
        #expect(decoded == value)
    }

    @Test("A wrong scalar type throws DecodingError")
    func wrongTypeThrows() {
        let data = Data("42".utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ClassSymbol.self, from: data)
        }
    }

    @Test("Values are usable in a Set, matching the ServerCapabilities.capabilities precedent")
    func hashableInSet() {
        let symbols: Set<ClassSymbol> = [.guardian, .guardian, .seeker]
        #expect(symbols.count == 2)
    }

    @Test("description exposes the raw wire string")
    func descriptionIsRawValue() {
        #expect(Difficulty.expert.description == "Expert")
    }
}
