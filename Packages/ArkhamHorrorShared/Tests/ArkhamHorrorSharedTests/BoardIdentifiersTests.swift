@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for ``CardCodeIdentifier`` and the `CodingKeyRepresentable` conformances this
/// contract slice adds to ``Identifier``/``CardCodeIdentifier``/``CardCode``, which let
/// `Dictionary<Identifier<Tag>, Value>`/`Dictionary<CardCode, Value>` decode/encode as
/// ordinary JSON objects through `ContractJSON` rather than the stdlib's flat
/// alternating-array fallback for non-`String`/`Int` keys.
@Suite("Board identifier decode")
struct BoardIdentifiersTests {
    @Test("A CardCodeIdentifier decodes and validates through CardCode's own initializer")
    func cardCodeIdentifierDecodesValid() throws {
        let id = try ContractJSON.decode(InvestigatorID.self, from: Data(#""c01001""#.utf8))
        #expect(id.rawValue.rawValue == "c01001")
        #expect(id.description == "c01001")
    }

    @Test("A CardCodeIdentifier rejects a malformed underlying CardCode")
    func cardCodeIdentifierRejectsMalformed() throws {
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(InvestigatorID.self, from: Data(#""not-c-prefixed""#.utf8))
        }
    }

    @Test("Two distinct CardCodeIdentifier tags wrapping the same CardCode are distinct types")
    func distinctCardCodeIdentifierTagsAreDistinctTypes() throws {
        let code = try CardCode("c01001")
        let investigatorID = InvestigatorID(code)
        let actID = ActID(code)
        #expect(investigatorID.rawValue == actID.rawValue)
    }

    @Test("[InvestigatorID: Int] round-trips through ContractJSON as a JSON object")
    func cardCodeKeyedDictionaryRoundTrips() throws {
        let original: [InvestigatorID: Int] = try [InvestigatorID(CardCode("c01001")): 3]
        let encoded = try ContractJSON.encode(original)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("\"c01001\""))
        let decoded = try ContractJSON.decode([InvestigatorID: Int].self, from: encoded)
        #expect(decoded == original)
    }

    @Test("[LocationID: Int] round-trips through ContractJSON as a JSON object")
    func uuidKeyedDictionaryRoundTrips() throws {
        let uuid = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000032"))
        let original: [LocationID: Int] = [LocationID(uuid): 7]
        let encoded = try ContractJSON.encode(original)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("00000000-0000-0000-0000-000000000032"))
        let decoded = try ContractJSON.decode([LocationID: Int].self, from: encoded)
        #expect(decoded == original)
    }

    @Test("A [LocationID: Int] object with a non-UUID key fails to decode")
    func uuidKeyedDictionaryRejectsInvalidKey() throws {
        let bytes = Data(#"{"totally-not-a-uuid": 1}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode([LocationID: Int].self, from: bytes)
        }
    }
}
