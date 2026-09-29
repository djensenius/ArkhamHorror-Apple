@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Create game request encoding from native options")
struct CreateGameRequestEncodingTests {
    @Test("Campaign option encodes Night of the Zealot campaign id and null scenario id")
    func campaignEncoding() throws {
        let viewModel = CreateGameViewModel()
        viewModel.playerCount = 2
        viewModel.difficulty = .standard
        let json = try encodedJSONObject(for: viewModel.makeRequest())

        #expect(json["campaignId"] as? String == "01")
        #expect(json["scenarioId"] is NSNull)
        #expect(json["playerCount"] as? Int == 2)
        #expect(json["difficulty"] as? String == "Standard")
        #expect(json["campaignName"] as? String == "The Night of the Zealot")
        #expect(json["multiplayerVariant"] as? String == "WithFriends")
        #expect(json["includeTarotReadings"] as? Bool == false)
        #expect(json["achievementsEnabled"] as? Bool == true)
        #expect(try #require(json["options"] as? [Any]).isEmpty)
        try expectNullDeckSlots(json, count: 2)
        expectDefaultableKeysOmitted(json)
    }

    @Test("Each standalone scenario option encodes its server scenario id and null campaign id")
    func standaloneScenarioEncoding() throws {
        for scenario in CreateGameCatalog.default.standaloneScenarios {
            let viewModel = CreateGameViewModel()
            viewModel.mode = .standaloneScenario
            viewModel.selectedScenarioID = scenario.id
            viewModel.customName = ""

            let json = try encodedJSONObject(for: viewModel.makeRequest())
            #expect(json["campaignId"] is NSNull)
            #expect(json["scenarioId"] as? String == scenario.id)
            #expect(json["campaignName"] as? String == scenario.title)
            #expect(json["achievementsEnabled"] as? Bool == true)
            try expectNullDeckSlots(json, count: 1)
        }
    }

    @Test("Difficulties encode the exact server enum strings")
    func difficultyEncoding() throws {
        let expected: [RequestDifficulty: String] = [
            .easy: "Easy",
            .standard: "Standard",
            .hard: "Hard",
            .expert: "Expert",
        ]

        for difficulty in RequestDifficulty.allCases {
            let viewModel = CreateGameViewModel()
            viewModel.difficulty = difficulty
            let json = try encodedJSONObject(for: viewModel.makeRequest())
            #expect(json["difficulty"] as? String == expected[difficulty])
        }
    }

    @Test("One-player requests encode one null deck slot and the web-default variant")
    func onePlayerEncoding() throws {
        let viewModel = CreateGameViewModel()
        viewModel.playerCount = 1
        let json = try encodedJSONObject(for: viewModel.makeRequest())

        #expect(json["playerCount"] as? Int == 1)
        #expect(json["multiplayerVariant"] as? String == "WithFriends")
        try expectNullDeckSlots(json, count: 1)
    }

    @Test("Multiplayer requests encode the selected variant for With Friends and multi-handed solo")
    func multiplayerVariantEncoding() throws {
        let withFriends = CreateGameViewModel()
        withFriends.playerCount = 3
        var json = try encodedJSONObject(for: withFriends.makeRequest())
        #expect(json["playerCount"] as? Int == 3)
        #expect(json["multiplayerVariant"] as? String == "WithFriends")
        try expectNullDeckSlots(json, count: 3)

        let multiHandedSolo = CreateGameViewModel()
        multiHandedSolo.playerCount = 3
        multiHandedSolo.multiplayerVariant = .solo
        json = try encodedJSONObject(for: multiHandedSolo.makeRequest())
        #expect(json["playerCount"] as? Int == 3)
        #expect(json["multiplayerVariant"] as? String == "Solo")
        try expectNullDeckSlots(json, count: 3)
    }

    private func encodedJSONObject(for request: CreateGameRequest) throws -> [String: Any] {
        let data = try ContractJSON.encode(request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func expectNullDeckSlots(_ json: [String: Any], count: Int) throws {
        let deckIds = try #require(json["deckIds"] as? [Any])
        #expect(deckIds.count == count)
        for deckID in deckIds {
            #expect(deckID is NSNull)
        }
    }

    private func expectDefaultableKeysOmitted(_ json: [String: Any]) {
        for key in ["strictAsIfAt", "asIfRuling", "ultimatumsAndBoons"] {
            #expect(json[key] == nil)
        }
    }
}
