@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("GameList")
struct GameListTests {
    private func loadFixture() throws -> GameList {
        let url = try #require(
            Bundle.module.url(
                forResource: "game-list",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try JSONDecoder().decode(GameList.self, from: Data(contentsOf: url))
    }

    // MARK: - All five fixture rows, exercising all four game states plus a failed row

    @Test("Row 0 is a pending game with a nullable-but-present scenario")
    func pendingRow() throws {
        let entries = try loadFixture()
        guard case let .game(summary) = entries[0] else {
            Issue.record("Expected .game")
            return
        }
        #expect(summary.id.rawValue.uuidString == "00000000-0000-0000-0000-000000000003")
        #expect(summary.scenario?.id == "c01104")
        #expect(summary.scenario?.difficulty == .easy)
        #expect(summary.scenario?.name == CardName(title: "The Gathering", subtitle: nil))
        #expect(summary.campaign == nil)
        #expect(summary.gameState == .pending([]))
        #expect(summary.multiplayerVariant == .solo)
        #expect(summary.hasOpenSeats == false)
    }

    @Test("Row 1 is a campaign game awaiting deck choices with investigators present")
    func chooseDecksRow() throws {
        let entries = try loadFixture()
        guard case let .game(summary) = entries[1] else {
            Issue.record("Expected .game")
            return
        }
        #expect(summary.scenario == nil)
        #expect(summary.campaign?.id == "06")
        #expect(summary.campaign?.difficulty == .easy)
        #expect(summary.campaign?.currentCampaignMode == .theDreamQuest)
        let expectedPlayer = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        #expect(summary.gameState == .chooseDecks([PlayerID(expectedPlayer)]))
        #expect(summary.investigators.map(\.classSymbol) == [.guardian, .seeker])
        #expect(summary.otherInvestigators.map(\.classSymbol) == [.rogue])
        #expect(summary.multiplayerVariant == .withFriends)
        #expect(summary.hasOpenSeats == true)
    }

    @Test("Row 2 is an active game (IsActive carries no contents)")
    func activeRow() throws {
        let entries = try loadFixture()
        guard case let .game(summary) = entries[2] else {
            Issue.record("Expected .game")
            return
        }
        #expect(summary.gameState == .active)
    }

    @Test("Row 3 is a completed game (IsOver carries no contents)")
    func overRow() throws {
        let entries = try loadFixture()
        guard case let .game(summary) = entries[3] else {
            Issue.record("Expected .game")
            return
        }
        #expect(summary.gameState == .over)
    }

    @Test("Row 4 is a failed game entry")
    func failedRow() throws {
        let entries = try loadFixture()
        guard case let .failed(entry) = entries[4] else {
            Issue.record("Expected .failed")
            return
        }
        #expect(entry.error == "Contract fixture failed to load.")
    }

    // MARK: - GameState: direct coverage of all four tags plus unknown fallback

    @Test("GameState.pending decodes and encodes its player UUID list")
    func gameStatePending() throws {
        let json = #"{"tag": "IsPending", "contents": ["00000000-0000-0000-0000-000000000001"]}"#
        let state = try JSONDecoder().decode(GameState.self, from: Data(json.utf8))
        let expectedPlayer = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        #expect(state == .pending([PlayerID(expectedPlayer)]))
        let reencoded = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(GameState.self, from: reencoded) == state)
    }

    @Test("GameState.active and .over encode without a contents key")
    func gameStateNoContentsEncoding() throws {
        for (state, tag) in [(GameState.active, "IsActive"), (GameState.over, "IsOver")] {
            let data = try JSONEncoder().encode(state)
            let json = try #require(String(data: data, encoding: .utf8))
            #expect(json.contains(tag))
            #expect(!json.contains("contents"))
        }
    }

    @Test("An unrecognized GameState tag decodes to .unknown, preserving its contents")
    func gameStateUnknownTag() throws {
        let json = #"{"tag": "IsPaused", "contents": {"reason": "maintenance"}}"#
        let state = try JSONDecoder().decode(GameState.self, from: Data(json.utf8))
        #expect(
            state
                == .unknown(
                    tag: "IsPaused",
                    contents: .object(["reason": .string("maintenance")])
                )
        )
    }

    // MARK: - GameListEntry union ambiguity

    @Test(
        "An object satisfying neither GameSummary nor FailedGameEntry throws, not silently succeeds"
    )
    func neitherShapeThrows() {
        let json = #"{"unexpected": true}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GameListEntry.self, from: Data(json.utf8))
        }
    }

    @Test("A well-formed GameSummary is preferred over FailedGameEntry when unambiguous")
    func gameSummaryDecodesAsGame() throws {
        let json = """
        {"id": "00000000-0000-0000-0000-000000000099", "scenario": null, "campaign": null,
         "gameState": {"tag": "IsActive"}, "name": "n", "investigators": [],
         "otherInvestigators": [], "multiplayerVariant": "Solo", "hasOpenSeats": false}
        """
        let entry = try JSONDecoder().decode(GameListEntry.self, from: Data(json.utf8))
        guard case .game = entry else {
            Issue.record("Expected .game")
            return
        }
    }

    // MARK: - Forward-compatible enums

    @Test("An unrecognized difficulty/currentCampaignMode string decodes losslessly")
    func unknownEnumStringsPreserved() throws {
        let json = """
        {"id": "01", "difficulty": "Nightmare", "currentCampaignMode": "TheFutureExpansion"}
        """
        let summary = try JSONDecoder().decode(CampaignSummary.self, from: Data(json.utf8))
        #expect(summary.difficulty == Difficulty("Nightmare"))
        #expect(summary.currentCampaignMode == CampaignMode("TheFutureExpansion"))
    }

    @Test("id fields (scenario/campaign/investigator) are plain strings, not CardCode-validated")
    func idFieldsAreUnvalidatedStrings() throws {
        let entries = try loadFixture()
        guard case let .game(summary) = entries[1] else {
            Issue.record("Expected .game")
            return
        }
        // "06" would fail CardCode validation (no 'c' prefix); it must still decode here.
        #expect(summary.campaign?.id == "06")
    }
}
