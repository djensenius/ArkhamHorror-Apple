@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Focused governed-fixture coverage for `Location`'s disjoint ordinary/enemy-spawned
/// shapes, discriminated by the literal `"enemyLocation": true` key.
@Suite("Location fixture decode")
struct LocationFixtureTests {
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

    @Test("An enemy-spawned pseudo-location decodes as .enemy with its smaller field set")
    func enemyLocationDecodes() throws {
        let location = try ContractJSON.decode(
            Location.self, from: fixtureData(named: "location-enemy-view")
        )
        guard case let .enemy(view) = location else {
            Issue.record("Expected .enemy")
            return
        }
        #expect(view.label == "shapeless_cellar")
        #expect(view.exhausted == false)
        #expect(view.shroud == .staticValue(4))
        #expect(view.placement == nil)
        #expect(try view.cardCode == CardCode("c10547"))
    }

    @Test("An ordinary location object without the enemyLocation key decodes as .ordinary")
    func ordinaryLocationDecodes() throws {
        let getGameData = try fixtureData(named: "get-game")
        let envelope = try ContractJSON.decode(GetGameEnvelope.self, from: getGameData)
        let locationID = try LocationID(
            #require(UUID(uuidString: "d5a66e84-c729-4066-8475-d8a155609025"))
        )
        guard case let .ordinary(location) = try #require(envelope.game.locations[locationID])
        else {
            Issue.record("Expected .ordinary")
            return
        }
        #expect(location.revealedSymbol == .circle)
        #expect(location.costToEnterUnrevealed.tag == "Free")
        #expect(location.investigateSkill == .intellect)
        #expect(location.revealClues == .perPlayer(2))
    }

    @Test("A location claiming enemyLocation: false fails with a typed discrimination error")
    func enemyLocationFlagFalseFails() throws {
        var fixture = try #require(
            String(data: fixtureData(named: "location-enemy-view"), encoding: .utf8)
        )
        fixture = fixture.replacingOccurrences(
            of: "\"enemyLocation\": true", with: "\"enemyLocation\": false"
        )
        #expect(throws: EnemyLocationViewError.enemyLocationFlagNotTrue) {
            _ = try ContractJSON.decode(Location.self, from: Data(fixture.utf8))
        }
    }

    @Test("An ordinary location missing its required symbol key fails with a coding path")
    func ordinaryLocationMissingRequiredKeyFails() throws {
        var fixture = try #require(
            String(data: fixtureData(named: "location-enemy-view"), encoding: .utf8)
        )
        // Strip the enemyLocation key so this routes to the ordinary decoder, which then
        // fails on ordinary-only required keys this fixture never carries (for example
        // "symbol").
        fixture = fixture.replacingOccurrences(of: "\"enemyLocation\": true,\n", with: "")
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(Location.self, from: Data(fixture.utf8))
        }
    }
}
