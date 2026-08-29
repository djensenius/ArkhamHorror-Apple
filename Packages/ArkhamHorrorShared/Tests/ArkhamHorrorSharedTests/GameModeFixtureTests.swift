@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Focused governed-fixture coverage for `PublicGame.mode`'s `Data.These`-shaped sibling
/// key encoding: the exact `This`-only, `That`-only, and `This`+`That` branches, plus
/// scenario turn zero.
@Suite("GameMode fixture decode")
struct GameModeFixtureTests {
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

    @Test("A That-only mode with scenario turn zero decodes as .scenarioOnly")
    func thatOnlyTurnZero() throws {
        let mode = try ContractJSON.decode(
            GameMode.self, from: fixtureData(named: "mode-turn-zero")
        )
        guard case let .scenarioOnly(scenario) = mode else {
            Issue.record("Expected .scenarioOnly")
            return
        }
        #expect(scenario.turn == 0)
    }

    @Test("A This-only mode decodes as .campaignOnly, preserving the broad campaign payload")
    func thisOnlyCampaign() throws {
        let mode = try ContractJSON.decode(
            GameMode.self, from: fixtureData(named: "mode-campaign-only")
        )
        guard case let .campaignOnly(campaign) = mode else {
            Issue.record("Expected .campaignOnly")
            return
        }
        guard case let .object(fields) = campaign else {
            Issue.record("Expected an object campaign payload")
            return
        }
        #expect(fields["name"] == .string("Night of the Zealot"))
        #expect(fields["difficulty"] == .string("Easy"))
    }

    @Test("A This+That mode decodes as .campaignAndScenario with both sibling payloads")
    func thisAndThatSibling() throws {
        let mode = try ContractJSON.decode(
            GameMode.self, from: fixtureData(named: "mode-campaign-scenario")
        )
        guard case let .campaignAndScenario(campaign, scenario) = mode else {
            Issue.record("Expected .campaignAndScenario")
            return
        }
        guard case let .object(fields) = campaign else {
            Issue.record("Expected an object campaign payload")
            return
        }
        #expect(fields["name"] == .string("Night of the Zealot"))
        #expect(scenario.turn == 0)
        #expect(scenario.name == CardName(title: "The Gathering", subtitle: nil))
        #expect(scenario.chaosBag.chaosTokens.isEmpty)
    }

    @Test("A mode object with neither This nor That fails with a typed decode error")
    func neitherThisNorThatFails() throws {
        let bytes = Data(#"{"Neither": true}"#.utf8)
        #expect(throws: GameModeError.missingThisAndThat) {
            _ = try ContractJSON.decode(GameMode.self, from: bytes)
        }
    }

    @Test("GameMode round-trips through ContractJSON encode/decode for the This+That branch")
    func roundTripsThroughEncode() throws {
        let mode = try ContractJSON.decode(
            GameMode.self, from: fixtureData(named: "mode-campaign-scenario")
        )
        let reencoded = try ContractJSON.encode(mode)
        let roundTripped = try ContractJSON.decode(GameMode.self, from: reencoded)
        #expect(mode == roundTripped)
    }
}
