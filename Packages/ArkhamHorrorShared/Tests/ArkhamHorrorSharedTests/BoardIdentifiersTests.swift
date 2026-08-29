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

    @Test("CardCode's CodingKeyRepresentable.init?(codingKey:) returns nil, never traps, on invalid input") // swiftlint:disable:this line_length
    func cardCodeCodingKeyRepresentableRejectsInvalidKeyWithoutTrapping() {
        // Exercises the `try? self.init(...)` delegating-initializer pattern in
        // `CardCode`'s `CodingKeyRepresentable` conformance directly (not merely through
        // `Decodable`, which uses a different code path): confirms a malformed key
        // safely produces `nil` rather than a partially-initialized value or a trap.
        #expect(CardCode(codingKey: AnyCodingKey(stringValue: "not-c-prefixed")) == nil)
        let valid = CardCode(codingKey: AnyCodingKey(stringValue: "c01001"))
        #expect(valid?.rawValue == "c01001")
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

    @Test("[LocationID: Int] round-trips through ContractJSON as a JSON object, case-preserved")
    func uuidKeyedDictionaryRoundTrips() throws {
        // A real hex-letter UUID (not only decimal digits) so an accidental
        // uppercase/lowercase mismatch in the map-key encoding is actually observable:
        // `Identifier`/`UUID` equality is case-insensitive, so a purely-decimal UUID like
        // `...-000000000032` cannot distinguish "encodes as uppercase" from "encodes as
        // lowercase" the way a fixture-realistic UUID such as this one can.
        let uuidString = "d5a66e84-c729-4066-8475-d8a155609025"
        let uuid = try #require(UUID(uuidString: uuidString))
        let original: [LocationID: Int] = [LocationID(uuid): 7]
        let encoded = try ContractJSON.encode(original)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains(uuidString), "Expected the lowercase wire form in: \(json)")
        #expect(!json.contains(uuidString.uppercased()))
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
