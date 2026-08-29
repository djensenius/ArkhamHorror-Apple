@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Focused governed-fixture coverage for `PublicGame`'s UUID- and `CardCode`-keyed broad
/// entity maps, and the `CodingKeyRepresentable` machinery that decodes/encodes them as
/// ordinary JSON objects rather than the stdlib's flat-array fallback.
@Suite("Entity map fixture decode")
struct EntityMapFixtureTests {
    private func fixtureData(named fileName: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: fileName,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    @Test("A UUID-keyed entity map decodes its key domain exactly, value as broad JSONValue")
    func uuidEntityMapDecodes() throws {
        let map = try ContractJSON.decode(
            UUIDEntityMap<EnemyIDTag>.self, from: fixtureData(named: "uuid-entity-map")
        )
        #expect(map.count == 1)
        let enemyID = try EnemyID(
            #require(UUID(uuidString: "00000000-0000-0000-0000-000000000384"))
        )
        guard case let .object(fields)? = map[enemyID] else {
            Issue.record("Expected an object value")
            return
        }
        #expect(fields["cardCode"] == .string("c01159"))
        #expect(fields["healthDamage"]?.kindDescription == "number")
    }

    @Test("A CardCode-keyed entity map decodes its key domain exactly, value as broad JSONValue")
    func cardCodeEntityMapDecodes() throws {
        let map = try ContractJSON.decode(
            CardCodeEntityMap.self, from: fixtureData(named: "card-code-entity-map")
        )
        #expect(map.count == 1)
        let code = try CardCode("c88023")
        guard case let .object(fields)? = map[code] else {
            Issue.record("Expected an object value")
            return
        }
        #expect(fields["flippedArt"] == .string("c88023b"))
    }

    @Test("A UUID entity map with an invalid (non-UUID) map key fails to decode")
    func invalidUUIDMapKeyFails() throws {
        let bytes = Data(#"{"not-a-uuid": {}}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(UUIDEntityMap<EnemyIDTag>.self, from: bytes)
        }
    }

    @Test("A CardCode entity map with an invalid (non-'c'-prefixed) map key fails to decode")
    func invalidCardCodeMapKeyFails() throws {
        let bytes = Data(#"{"not-a-card-code": {}}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(CardCodeEntityMap.self, from: bytes)
        }
    }

    @Test("An entity map round-trips through ContractJSON encode/decode, preserving keys")
    func entityMapRoundTrips() throws {
        let map = try ContractJSON.decode(
            UUIDEntityMap<EnemyIDTag>.self, from: fixtureData(named: "uuid-entity-map")
        )
        let reencoded = try ContractJSON.encode(map)
        let roundTripped = try ContractJSON.decode(UUIDEntityMap<EnemyIDTag>.self, from: reencoded)
        #expect(map == roundTripped)
    }

    @Test("PublicGame's distinctly-tagged entity id domains cannot be interchanged")
    func distinctEntityIDDomainsAreNotInterchangeable() throws {
        let uuid = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let enemyID = EnemyID(uuid)
        let assetID = AssetID(uuid)
        // Both wrap the identical UUID, but are different Swift types: this line would
        // fail to compile if uncommented, which is exactly the point.
        // #expect(enemyID == assetID)
        #expect(enemyID.rawValue == assetID.rawValue)
    }
}
