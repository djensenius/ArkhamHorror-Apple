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
                subdirectory: "Fixtures/Contract"
            )
        )
        return try ContractJSON.decode(GameLifecycleFixture.self, from: Data(contentsOf: url))
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
        #expect(request.campaignOrScenario == .campaignOnly(campaignId: "01"))
        #expect(request.campaignOrScenario.campaignId == "01")
        #expect(request.campaignOrScenario.scenarioId == nil)
        #expect(request.difficulty == .standard)
        #expect(request.campaignName == "Contract campaign")
        #expect(request.multiplayerVariant == .withFriends)
        #expect(request.includeTarotReadings == true)
        #expect(
            request.options == [
                .flag(.performIntro), .campaignVariant("return-to"),
            ]
        )
        #expect(request.strictAsIfAt == .value(false))
        #expect(request.asIfRuling == .value(.chapter1))
        #expect(
            request.ultimatumsAndBoons == .value([
                .boonOfHades, .ultimatumOfChaos,
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
        #expect(request.campaignOrScenario == .scenarioOnly(scenarioId: "01104"))
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
        let data = try ContractJSON.encode(fixture.createGameDefaults)
        let json = try #require(String(data: data, encoding: .utf8))
        for key in ["strictAsIfAt", "asIfRuling", "ultimatumsAndBoons", "achievementsEnabled"] {
            #expect(!json.contains(key), "Expected '\(key)' to be omitted, got: \(json)")
        }
    }

    @Test("Encoding createGameNullDefaults emits explicit null for every defaultable key")
    func encodeEmitsExplicitNulls() throws {
        let fixture = try loadFixture()
        let data = try ContractJSON.encode(fixture.createGameNullDefaults)
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
        let data = try ContractJSON.encode(fixture.createGame)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"strictAsIfAt\":false"))
        #expect(json.contains("\"achievementsEnabled\":false"))
        #expect(json.contains("\"asIfRuling\":\"chapter1\""))
    }

    @Test("campaignId and scenarioId are both always written, one as null")
    func campaignAndScenarioAlwaysBothPresent() throws {
        let fixture = try loadFixture()
        let data = try ContractJSON.encode(fixture.createGame)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"campaignId\":\"01\""))
        #expect(json.contains("\"scenarioId\":null"))
    }

    // MARK: - campaign/scenario invariant (construction time)

    //
    // `CampaignOrScenario`'s validating initializer is the single point where this
    // invariant is enforced — both `CreateGameRequest.encode(to:)` and `init(from:)` route
    // through an already-validated `CampaignOrScenario`, so there is no longer a way to
    // reach an encode-time-only failure: an invalid combination is rejected the moment
    // someone tries to construct one, whether directly or by decoding.

    @Test("Constructing throws when both campaignId and scenarioId are nil")
    func missingBothThrows() {
        #expect(throws: CampaignOrScenario.ValidationError.missingCampaignOrScenario) {
            try makeMinimalRequest(campaignId: nil, scenarioId: nil)
        }
    }

    @Test("Constructing throws when both campaignId and scenarioId are empty strings")
    func bothEmptyThrows() {
        // Per `CampaignOrScenario.init`, the empty-`campaignId` check happens before the
        // missing-both check, so this is `.emptyCampaignId`, not `.missingCampaignOrScenario`.
        #expect(throws: CampaignOrScenario.ValidationError.emptyCampaignId) {
            try makeMinimalRequest(campaignId: "", scenarioId: "")
        }
    }

    @Test("Constructing throws when campaignId is non-empty but scenarioId is an empty string")
    func nonEmptyCampaignWithEmptyScenarioThrows() {
        #expect(throws: CampaignOrScenario.ValidationError.emptyScenarioId) {
            try makeMinimalRequest(campaignId: "01", scenarioId: "")
        }
    }

    @Test("Constructing throws when scenarioId is non-empty but campaignId is an empty string")
    func nonEmptyScenarioWithEmptyCampaignThrows() {
        #expect(throws: CampaignOrScenario.ValidationError.emptyCampaignId) {
            try makeMinimalRequest(campaignId: "", scenarioId: "01104")
        }
    }

    @Test("Encoding succeeds when only scenarioId is present")
    func onlyScenarioSucceeds() throws {
        let request = try makeMinimalRequest(campaignId: nil, scenarioId: "01104")
        let data = try ContractJSON.encode(request)
        #expect(!data.isEmpty)
    }

    @Test("Encoding succeeds when both campaignId and scenarioId are present")
    func bothPresentSucceeds() throws {
        let request = try makeMinimalRequest(campaignId: "01", scenarioId: "01104")
        let data = try ContractJSON.encode(request)
        #expect(!data.isEmpty)
    }

    private func makeMinimalRequest(
        campaignId: String?,
        scenarioId: String?
    ) throws -> CreateGameRequest {
        try CreateGameRequest(
            deckIds: [],
            playerCount: 1,
            campaignOrScenario: CampaignOrScenario(campaignId: campaignId, scenarioId: scenarioId),
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

    // MARK: - ChooseDeckRequest / ClaimSeatRequest / OpenSeats

    @Test("chooseDeck decodes investigatorId without the 'c' prefix and ignores unknownField")
    func chooseDeckRequest() throws {
        let fixture = try loadFixture()
        #expect(fixture.chooseDeck.investigatorId.rawValue == "01001")
        #expect(fixture.chooseDeck.deckUrl == "https://arkhamdb.com/decklist/view/4242")
        #expect(fixture.chooseDeck.deckList?.investigatorCode.rawValue == "01001")
    }

    @Test("continueWithoutUpgrade decodes investigatorId with the 'c' prefix")
    func continueWithoutUpgradeRequest() throws {
        let fixture = try loadFixture()
        #expect(fixture.continueWithoutUpgrade.investigatorId.rawValue == "c01001")
    }

    @Test("claimSeat decodes investigatorId and ignores unknownField")
    func claimSeatRequest() throws {
        let fixture = try loadFixture()
        #expect(fixture.claimSeat.investigatorId.rawValue == "01001")
    }

    @Test("An empty investigatorId is rejected before it could ever be encoded")
    func emptyInvestigatorIdRejected() {
        #expect(throws: (any Error).self) {
            try ClaimSeatRequest(investigatorId: InvestigatorCode(""))
        }
    }

    @Test("openSeats decodes a list of validated CardCodes")
    func openSeatsDecodes() throws {
        let fixture = try loadFixture()
        #expect(fixture.openSeats.map(\.rawValue) == ["c01001", "c01002"])
    }

    @Test("A malformed openSeats entry (missing 'c' prefix) throws DecodingError")
    func openSeatsMalformedEntryThrows() {
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(OpenSeats.self, from: Data(#"["01001"]"#.utf8))
        }
    }
}
