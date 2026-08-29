@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Mirrors `contracts/fixtures/game-lifecycle.json`'s combined shape. No production
/// endpoint returns this combined shape; each key matches an independent request/response
/// type, decoded here for fixture-based testing convenience only.
private struct GameLifecycleFixture: Decodable {
    let createGame: CreateGameRequest
    let createGameDefaults: CreateGameRequest
    let createGameNullDefaults: CreateGameRequest
    let chooseDeck: ChooseDeckRequest
    let continueWithoutUpgrade: ChooseDeckRequest
    let claimSeat: ClaimSeatRequest
    let openSeats: OpenSeats
}

@Suite("GameLifecycle")
struct GameLifecycleTests {
    private func loadFixture() throws -> GameLifecycleFixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "game-lifecycle",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try JSONDecoder().decode(GameLifecycleFixture.self, from: Data(contentsOf: url))
    }

    // MARK: - createGame: every defaultable field present with a value

    @Test("createGame decodes deckIds with a null entry and every defaultable field's value")
    func createGameWithValues() throws {
        let fixture = try loadFixture()
        let request = fixture.createGame
        #expect(request.deckIds.count == 2)
        #expect(request.deckIds[0]?.rawValue.uuidString == "00000000-0000-0000-0000-000000000017")
        #expect(request.deckIds[1] == nil)
        #expect(request.playerCount == 2)
        #expect(request.campaignId == "01")
        #expect(request.scenarioId == nil)
        #expect(request.difficulty == .standard)
        #expect(request.campaignName == "Contract campaign")
        #expect(request.multiplayerVariant == .withFriends)
        #expect(request.includeTarotReadings == true)
        #expect(
            request.options == [
                .flag(CampaignOptionFlag("PerformIntro")), .campaignVariant("return-to"),
            ]
        )
        #expect(request.strictAsIfAt == .value(false))
        #expect(request.asIfRuling == .value(.chapter1))
        #expect(
            request.ultimatumsAndBoons == .value([
                UltimatumOrBoon("BoonOfHades"), UltimatumOrBoon("UltimatumOfChaos"),
            ])
        )
        #expect(request.achievementsEnabled == .value(false))
    }

    // MARK: - createGameDefaults: every defaultable field absent

    @Test("createGameDefaults leaves every defaultable field .absent")
    func createGameDefaultsAllAbsent() throws {
        let fixture = try loadFixture()
        let request = fixture.createGameDefaults
        #expect(request.deckIds.isEmpty)
        #expect(request.campaignId == nil)
        #expect(request.scenarioId == "01104")
        #expect(request.strictAsIfAt == .absent)
        #expect(request.asIfRuling == .absent)
        #expect(request.ultimatumsAndBoons == .absent)
        #expect(request.achievementsEnabled == .absent)
    }

    // MARK: - createGameNullDefaults: every defaultable field explicit null

    @Test("createGameNullDefaults leaves every defaultable field .null")
    func createGameNullDefaultsAllNull() throws {
        let fixture = try loadFixture()
        let request = fixture.createGameNullDefaults
        #expect(request.strictAsIfAt == .null)
        #expect(request.asIfRuling == .null)
        #expect(request.ultimatumsAndBoons == .null)
        #expect(request.achievementsEnabled == .null)
    }

    // MARK: - Exact wire shape on encode: absent omits, null is explicit, value is present

    @Test("Encoding createGameDefaults omits every absent defaultable key")
    func encodeOmitsAbsentKeys() throws {
        let fixture = try loadFixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(fixture.createGameDefaults)
        let json = try #require(String(data: data, encoding: .utf8))
        for key in ["strictAsIfAt", "asIfRuling", "ultimatumsAndBoons", "achievementsEnabled"] {
            #expect(!json.contains(key), "Expected '\(key)' to be omitted, got: \(json)")
        }
    }

    @Test("Encoding createGameNullDefaults emits explicit null for every defaultable key")
    func encodeEmitsExplicitNulls() throws {
        let fixture = try loadFixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(fixture.createGameNullDefaults)
        let json = try #require(String(data: data, encoding: .utf8))
        for key in ["strictAsIfAt", "asIfRuling", "ultimatumsAndBoons", "achievementsEnabled"] {
            #expect(
                json.contains("\"\(key)\":null"),
                "Expected explicit null for '\(key)', got: \(json)"
            )
        }
    }

    @Test("Encoding createGame emits each defaultable key's actual value")
    func encodeEmitsValues() throws {
        let fixture = try loadFixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(fixture.createGame)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"strictAsIfAt\":false"))
        #expect(json.contains("\"achievementsEnabled\":false"))
        #expect(json.contains("\"asIfRuling\":\"chapter1\""))
    }

    @Test("campaignId and scenarioId are both always written, one as null")
    func campaignAndScenarioAlwaysBothPresent() throws {
        let fixture = try loadFixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(fixture.createGame)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"campaignId\":\"01\""))
        #expect(json.contains("\"scenarioId\":null"))
    }

    // MARK: - campaign/scenario invariant

    @Test("Encoding throws when both campaignId and scenarioId are nil")
    func missingBothThrows() throws {
        let request = try makeMinimalRequest(campaignId: nil, scenarioId: nil)
        #expect(throws: CreateGameRequestError.missingCampaignOrScenario) {
            try JSONEncoder().encode(request)
        }
    }

    @Test("Encoding throws when both campaignId and scenarioId are empty strings")
    func bothEmptyThrows() throws {
        let request = try makeMinimalRequest(campaignId: "", scenarioId: "")
        #expect(throws: CreateGameRequestError.missingCampaignOrScenario) {
            try JSONEncoder().encode(request)
        }
    }

    @Test("Encoding succeeds when only scenarioId is present")
    func onlyScenarioSucceeds() throws {
        let request = try makeMinimalRequest(campaignId: nil, scenarioId: "01104")
        let data = try JSONEncoder().encode(request)
        #expect(!data.isEmpty)
    }

    @Test("Encoding succeeds when both campaignId and scenarioId are present")
    func bothPresentSucceeds() throws {
        let request = try makeMinimalRequest(campaignId: "01", scenarioId: "01104")
        let data = try JSONEncoder().encode(request)
        #expect(!data.isEmpty)
    }

    private func makeMinimalRequest(
        campaignId: String?,
        scenarioId: String?
    ) throws -> CreateGameRequest {
        CreateGameRequest(
            deckIds: [],
            playerCount: 1,
            campaignId: campaignId,
            scenarioId: scenarioId,
            difficulty: .easy,
            campaignName: "Test",
            multiplayerVariant: .solo,
            includeTarotReadings: false,
            options: [],
            strictAsIfAt: .absent,
            asIfRuling: .absent,
            ultimatumsAndBoons: .absent,
            achievementsEnabled: .absent
        )
    }

    // MARK: - CampaignOption: known flag, unknown flag, and CampaignVariant

    @Test("A known campaign option flag decodes to .flag, never .unknown")
    func knownFlagDecodes() throws {
        let decoded = try JSONDecoder().decode(
            CampaignOption.self,
            from: Data(#"{"tag": "PerformIntro"}"#.utf8)
        )
        #expect(decoded == .flag(CampaignOptionFlag("PerformIntro")))
    }

    @Test(
        "A genuinely unrecognized tag decodes to .unknown, never silently treated as a known flag"
    )
    func unrecognizedTagDecodesToUnknown() throws {
        let decoded = try JSONDecoder().decode(
            CampaignOption.self,
            from: Data(#"{"tag": "SomeFutureFlagNotYetKnown"}"#.utf8)
        )
        guard case let .unknown(tag, _) = decoded else {
            Issue.record("Expected .unknown, got \(decoded)")
            return
        }
        #expect(tag == "SomeFutureFlagNotYetKnown")
    }

    @Test("CampaignVariant decodes its string contents")
    func campaignVariantDecodes() throws {
        let decoded = try JSONDecoder().decode(
            CampaignOption.self,
            from: Data(#"{"tag": "CampaignVariant", "contents": "return-to"}"#.utf8)
        )
        #expect(decoded == .campaignVariant("return-to"))
    }

    @Test("An unknown CampaignOption re-encodes with its original tag, still distinct from .flag")
    func unknownOptionRoundTrips() throws {
        let original = CampaignOption.unknown(tag: "SomeFutureFlagNotYetKnown", contents: nil)
        let data = try JSONEncoder().encode(original)
        let redecoded = try JSONDecoder().decode(CampaignOption.self, from: data)
        #expect(redecoded == original)
        if case .flag = redecoded {
            Issue.record("An unknown option must never decode back as .flag")
        }
    }

    // MARK: - ChooseDeckRequest / ClaimSeatRequest / OpenSeats

    @Test("chooseDeck decodes investigatorId without the 'c' prefix and ignores unknownField")
    func chooseDeckRequest() throws {
        let fixture = try loadFixture()
        #expect(fixture.chooseDeck.investigatorId == "01001")
        #expect(fixture.chooseDeck.deckUrl == "https://arkhamdb.com/decklist/view/4242")
        #expect(fixture.chooseDeck.deckList?.investigatorCode == "01001")
    }

    @Test("continueWithoutUpgrade decodes investigatorId with the 'c' prefix")
    func continueWithoutUpgradeRequest() throws {
        let fixture = try loadFixture()
        #expect(fixture.continueWithoutUpgrade.investigatorId == "c01001")
    }

    @Test("claimSeat decodes investigatorId and ignores unknownField")
    func claimSeatRequest() throws {
        let fixture = try loadFixture()
        #expect(fixture.claimSeat.investigatorId == "01001")
    }

    @Test("openSeats decodes a list of validated CardCodes")
    func openSeatsDecodes() throws {
        let fixture = try loadFixture()
        #expect(fixture.openSeats.map(\.rawValue) == ["c01001", "c01002"])
    }

    @Test("A malformed openSeats entry (missing 'c' prefix) throws DecodingError")
    func openSeatsMalformedEntryThrows() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(OpenSeats.self, from: Data(#"["01001"]"#.utf8))
        }
    }
}
