@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Mirrors `contracts/fixtures/game-lifecycle.json`'s combined shape. No production
/// endpoint returns this combined shape; each key matches an independent request/response
/// type, decoded here for fixture-based testing convenience only.
///
/// Split out of ``GameLifecycleTests`` (which keeps its own private copy of this same
/// fixture-loading helper) purely to stay under SwiftLint's file/type length limits; this
/// suite covers issue #6's closed request-side enums specifically.
private struct GameLifecycleRequestEnumFixture: Decodable {
    let createGame: CreateGameRequest
}

@Suite("GameLifecycle closed request-side enums (issue #6)")
struct GameLifecycleRequestEnumTests {
    private func loadFixture() throws -> GameLifecycleRequestEnumFixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "game-lifecycle",
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try JSONDecoder().decode(
            GameLifecycleRequestEnumFixture.self,
            from: Data(contentsOf: url)
        )
    }

    @Test("RequestDifficulty has no case for a server-reported-only difficulty like Nightmare")
    func requestDifficultyCannotRepresentNightmare() {
        #expect(RequestDifficulty(rawValue: "Nightmare") == nil)
        #expect(RequestDifficulty.allCases.map(\.rawValue).contains("Nightmare") == false)
    }

    @Test("Decoding RequestDifficulty from an unrecognized string throws, unlike Difficulty")
    func requestDifficultyDecodeUnrecognizedThrows() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RequestDifficulty.self, from: Data(#""Nightmare""#.utf8))
        }
        // Contrast: the response-side, open Difficulty tolerates the same string.
        #expect(throws: Never.self) {
            try JSONDecoder().decode(Difficulty.self, from: Data(#""Nightmare""#.utf8))
        }
    }

    @Test("RequestMultiplayerVariant has no case for a server-reported-only variant like Coop")
    func requestMultiplayerVariantCannotRepresentCoop() {
        #expect(RequestMultiplayerVariant(rawValue: "Coop") == nil)
    }

    @Test("AsIfRuling has no case for a future ruling this client build doesn't recognize")
    func asIfRulingCannotRepresentFutureRuling() {
        #expect(AsIfRuling(rawValue: "Chapter3AsIfRuling") == nil)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AsIfRuling.self, from: Data(#""Chapter3AsIfRuling""#.utf8))
        }
    }

    @Test("UltimatumOrBoon has no case for a future boon this client build doesn't recognize")
    func ultimatumOrBoonCannotRepresentFutureBoon() {
        #expect(UltimatumOrBoon(rawValue: "BoonOfSomeNewGod") == nil)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UltimatumOrBoon.self, from: Data(#""BoonOfSomeNewGod""#.utf8))
        }
    }

    @Test("An encoded CreateGameRequest can never contain Nightmare, Coop, or a future ruling")
    func encoderCannotEmitUnrecognizedRequestValues() throws {
        let fixture = try loadFixture()
        let encoder = JSONEncoder()
        let data = try encoder.encode(fixture.createGame)
        let json = try #require(String(data: data, encoding: .utf8))
        // Not a claim that these substrings can never appear for other reasons: a proof
        // that the *closed enum's own case set* is what makes them unconstructible, not an
        // incidental absence from this particular fixture value.
        #expect(RequestDifficulty.allCases.allSatisfy { $0.rawValue != "Nightmare" })
        #expect(RequestMultiplayerVariant.allCases.allSatisfy { $0.rawValue != "Coop" })
        #expect(AsIfRuling.allCases.allSatisfy { $0.rawValue != "Chapter3AsIfRuling" })
        #expect(UltimatumOrBoon.allCases.allSatisfy { $0.rawValue != "BoonOfSomeNewGod" })
        #expect(!json.isEmpty)
    }

    @Test("An empty ChooseDeckRequest.investigatorId is rejected before it could be encoded")
    func chooseDeckEmptyInvestigatorIdRejected() {
        #expect(throws: (any Error).self) {
            try ChooseDeckRequest(
                investigatorId: InvestigatorCode(""),
                deckUrl: nil,
                deckList: nil
            )
        }
    }

    @Test("An empty DeckListInput.investigatorCode is rejected before it could be encoded")
    func deckListInputEmptyInvestigatorCodeRejected() {
        #expect(throws: (any Error).self) {
            try DeckListInput(
                slots: CardQuantityMapInput([:]),
                sideSlots: .absent,
                investigatorCode: InvestigatorCode(""),
                investigatorName: nil,
                meta: nil,
                tabooId: nil,
                url: nil,
                id: nil,
                name: nil
            )
        }
    }
}
