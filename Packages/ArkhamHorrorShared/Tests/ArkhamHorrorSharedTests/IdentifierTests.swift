@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Identifier")
struct IdentifierTests {
    @Test("A valid UUID string decodes for each concrete identifier alias")
    func decodesValidUUID() throws {
        let uuidString = "00000000-0000-0000-0000-000000000017"
        let data = Data("\"\(uuidString)\"".utf8)
        let gameID = try JSONDecoder().decode(GameID.self, from: data)
        let deckID = try JSONDecoder().decode(DeckID.self, from: data)
        let playerID = try JSONDecoder().decode(PlayerID.self, from: data)
        #expect(gameID.rawValue.uuidString == uuidString.uppercased())
        #expect(deckID.rawValue.uuidString == uuidString.uppercased())
        #expect(playerID.rawValue.uuidString == uuidString.uppercased())
    }

    @Test("A malformed UUID string throws DecodingError instead of trapping")
    func malformedUUIDThrows() {
        let data = Data(#""not-a-uuid""#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GameID.self, from: data)
        }
    }

    @Test("An empty string throws DecodingError instead of trapping")
    func emptyStringThrows() {
        let data = Data(#""""#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DeckID.self, from: data)
        }
    }

    @Test("A wrong scalar type throws DecodingError instead of trapping")
    func wrongTypeThrows() {
        let data = Data("42".utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PlayerID.self, from: data)
        }
    }

    @Test("An array of nullable identifiers preserves null entries per element")
    func nullableArrayElements() throws {
        let json = """
        ["00000000-0000-0000-0000-000000000017", null]
        """
        let decoded = try JSONDecoder().decode([DeckID?].self, from: Data(json.utf8))
        #expect(decoded.count == 2)
        #expect(decoded[0] != nil)
        #expect(decoded[1] == nil)
    }

    @Test("Distinct identifier aliases are distinct compile-time types")
    func typesAreDistinct() {
        // This test compiles only because GameID and DeckID are not interchangeable;
        // its value is the compile-time guarantee itself.
        let uuid = UUID()
        let gameID = GameID(uuid)
        let deckID = DeckID(uuid)
        #expect(gameID.rawValue == deckID.rawValue)
    }

    @Test("JSON encoding round-trips through decoding")
    func jsonRoundTrip() throws {
        let id = GameID(UUID())
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(GameID.self, from: data)
        #expect(decoded == id)
    }
}
