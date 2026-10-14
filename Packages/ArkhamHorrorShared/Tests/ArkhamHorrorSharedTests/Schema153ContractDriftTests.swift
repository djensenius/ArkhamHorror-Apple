@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Schema 0.1.53 contract drift")
struct Schema153ContractDriftTests {
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

    @Test("0.1.53 get-game forceDraw array decodes from captured fixture bytes")
    func forceDrawArrayDecodesFromVendoredFixture() throws {
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: fixtureData(named: "get-game")
        )
        let scenario = try #require(scenario(in: envelope.game.mode))
        #expect(scenario.chaosBag.forceDraw == [])
    }

    @Test("0.1.52 forceDraw string and null shapes still decode")
    func legacyForceDrawShapesStillDecode() throws {
        let stringEnvelope = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: mutateGetGame { game in
                var mode = try object(game["mode"])
                var scenario = try object(mode["That"])
                var bag = try object(scenario["chaosBag"])
                bag["forceDraw"] = "ElderSign"
                scenario["chaosBag"] = bag
                mode["That"] = scenario
                game["mode"] = mode
            }
        )
        let stringScenario = try #require(scenario(in: stringEnvelope.game.mode))
        #expect(stringScenario.chaosBag.forceDraw == [.elderSign])

        let nullEnvelope = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: mutateGetGame { game in
                var mode = try object(game["mode"])
                var scenario = try object(mode["That"])
                var bag = try object(scenario["chaosBag"])
                bag["forceDraw"] = NSNull()
                scenario["chaosBag"] = bag
                mode["That"] = scenario
                game["mode"] = mode
            }
        )
        #expect(try #require(scenario(in: nullEnvelope.game.mode)).chaosBag.forceDraw == [])
    }

    @Test("structured public-game log decodes and renders captured rows")
    func structuredLogDecodesAndRenders() throws {
        let snapshot = try ContractJSON.decode(
            PublicGameSnapshot.self,
            from: fixtureData(named: "public-game-structured-log")
        )
        let viewer = try PlayerID(#require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )))
        let other = try PlayerID(#require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000099"
        )))

        #expect(snapshot.log.count == 3)
        let viewerText = snapshot.log.compactMap { $0.renderedText(for: viewer) }
        #expect(viewerText.contains("Legacy contract fixture row."))
        #expect(viewerText.contains { $0.contains("Everyone sees Contract fixture card") })
        #expect(viewerText.contains("Private contract row."))
        let otherText = snapshot.log.compactMap { $0.renderedText(for: other) }
        #expect(!otherText.contains("Private contract row."))
    }

    @Test("legacy string logs and malformed rows do not fail the snapshot")
    func legacyAndMalformedLogRowsAreLossyPerRow() throws {
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: mutateGetGame { game in
                game["log"] = [
                    "legacy text row",
                    42,
                    ["tag": "LogRowLegacy", "contents": "legacy object row"],
                ]
            }
        )
        let rendered = envelope.game.log.compactMap { $0.renderedText() }
        #expect(rendered == ["legacy text row", "legacy object row"])
    }

    @Test("RoomClosed captured WebSocket message decodes to terminal room-closed case")
    func roomClosedDecodes() throws {
        let update = try ContractJSON.decode(
            BoardSnapshotUpdate.self,
            from: fixtureData(named: "room-closed")
        )
        #expect(update == .roomClosed(reason: "deleted"))
    }

    @Test("game-list failed row carries id and name for display/delete")
    func gameListFailedRowCarriesIDAndName() throws {
        let list = try ContractJSON.decode(GameList.self, from: fixtureData(named: "game-list"))
        let failed = try #require(list.compactMap { entry -> FailedGameEntry? in
            if case let .failed(row) = entry {
                row
            } else {
                nil
            }
        }.first)
        #expect(
            failed.id?.rawValue.uuidString.lowercased()
                == "00000000-0000-0000-0000-000000000007"
        )
        #expect(failed.name == "Broken contract fixture")
        #expect(failed.error == "Contract fixture failed to load.")
        #expect(list.contains { $0.gameID == failed.id })
    }

    @Test("campaign catalog floodRules are additive")
    func campaignCatalogFloodRulesAreIgnoredAdditively() throws {
        var root = try object(JSONSerialization.jsonObject(
            with: fixtureData(named: "campaign-catalog")
        ))
        var campaigns = try #require(root["campaigns"] as? [[String: Any]])
        var campaign = try #require(campaigns.first)
        campaign["floodRules"] = ["rising", "flooded"]
        campaigns[0] = campaign
        root["campaigns"] = campaigns
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

        let document = try ContractJSON.decode(CampaignCatalogDocument.self, from: data)
        #expect(document.campaigns.first?.id == campaign["id"] as? String)
    }

    @MainActor
    @Test("RoomClosed closes the live room instead of retrying")
    func roomClosedMarksGameDeleted() async throws {
        let (model, _) = AppModelLiveGameTests().makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = AppModelLiveGameTests().installCurrentAttempt(for: gameID, on: model)
        let envelope = try ContractJSON.decode(
            GetGameEnvelope.self,
            from: fixtureData(named: "get-game")
        )
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        let connection = FakeGameSocketConnection()
        let roomClosed = try fixtureData(named: "room-closed")
        await connection.enqueue(.event(.message(roomClosed)))

        let outcome = await model.consumeLiveGameSocket(
            attempt,
            connection: connection,
            projection: projection
        )
        #expect(outcome == .stopped)
        #expect(model.confirmedDeletedGameIDs.contains(gameID))
        await connection.waitUntilClosed()
    }

    private func scenario(in mode: GameMode) -> Scenario? {
        switch mode {
        case let .scenarioOnly(scenario), let .campaignAndScenario(_, scenario):
            scenario
        case .campaignOnly:
            nil
        }
    }

    private enum MutationError: Error {
        case unexpectedShape
    }

    private func mutateGetGame(_ mutate: (inout [String: Any]) throws -> Void) throws -> Data {
        var root = try object(JSONSerialization.jsonObject(with: fixtureData(named: "get-game")))
        var game = try object(root["game"])
        try mutate(&game)
        root["game"] = game
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func object(_ value: Any?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw MutationError.unexpectedShape }
        return object
    }
}
