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
        let decodedScenario = try #require(contractScenario(in: envelope.game.mode))
        #expect(decodedScenario.chaosBag.forceDraw == [])
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
        let stringScenario = try #require(contractScenario(in: stringEnvelope.game.mode))
        let encodedStringForceDraw = try encodedForceDrawValue(in: stringEnvelope)
        #expect(stringScenario.chaosBag.forceDraw == [.elderSign])
        #expect(encodedStringForceDraw == .array([.string("ElderSign")]))

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
        let nullScenario = try #require(contractScenario(in: nullEnvelope.game.mode))
        let encodedNullForceDraw = try encodedForceDrawValue(in: nullEnvelope)
        #expect(nullScenario.chaosBag.forceDraw == [])
        #expect(encodedNullForceDraw == .array([]))
    }

    @Test("structured public-game log decodes captured rows and filters audiences")
    func structuredLogDecodesAndFiltersAudiences() throws {
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
        #expect(snapshot.log.map { $0.isVisible(to: viewer) } == [true, true, true])
        #expect(snapshot.log.map { $0.isVisible(to: other) } == [true, true, false])
        #expect(snapshot.log.map { $0.isVisible(to: nil) } == [true, true, false])

        guard case let .legacy(text, step) = snapshot.log[0] else {
            Issue.record("Expected legacy log row")
            return
        }
        #expect(text == "Legacy contract fixture row.")
        #expect(step == 7)

        guard case let .structured(publicEntry) = snapshot.log[1] else {
            Issue.record("Expected public structured log row")
            return
        }
        #expect(publicEntry.seq == 1)
        #expect(publicEntry.children.count == 1)
        #expect(publicEntry.children[0].seq == 0)
        #expect(publicEntry.children[0].body == [.text("Nested contract child.")])
        #expect(publicEntry.body.count == 3)
        #expect(publicEntry.body[0] == .text("Everyone sees "))
        guard case let .i18n(key, variables) = publicEntry.body[2] else {
            Issue.record("Expected structured LogI18n part")
            return
        }
        #expect(key == "contract.log.everyone")
        #expect(variables["count"] == .number(.integer(2)))

        guard case let .structured(privateEntry) = snapshot.log[2] else {
            Issue.record("Expected private structured log row")
            return
        }
        #expect(privateEntry.audience == .onlyPlayer(viewer))
        #expect(privateEntry.body == [.text("Private contract row.")])
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
        let legacyRows = envelope.game.log.compactMap(legacyLogText)
        #expect(legacyRows == ["legacy text row", "legacy object row"])
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
    @Test("RoomClosed closes the live room and leaves a list-level notice")
    func roomClosedMarksGameDeletedAndSurfacesNotice() async throws {
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
        #expect(model.liveGameState(for: gameID) == .roomClosed(
            reason: "deleted",
            lastKnown: projection
        ))
        #expect(!model.liveGameState(for: gameID).isRetryable)
        #expect(liveGameRoomClosedTitle() == "Game closed")
        #expect(liveGameRoomClosedMessage() == "This game was closed on the server.")

        let notice = try #require(model.roomClosedNotice)
        #expect(notice == RoomClosedNotice(gameID: gameID, reason: "deleted"))

        var presentedGameID: GameID?
        var liveGamePath = [gameID]
        OpenGameSurfaceReconciler.reconcile(
            presentedGameID: &presentedGameID,
            liveGamePath: &liveGamePath,
            gameListState: .loaded([]),
            confirmedDeletedGameIDs: model.confirmedDeletedGameIDs
        )
        #expect(liveGamePath == [])
        #expect(model.roomClosedNotice == notice)

        model.dismissRoomClosedNotice()
        #expect(model.roomClosedNotice == nil)
        await connection.waitUntilClosed()
    }

    private func contractScenario(in mode: GameMode) -> Scenario? {
        switch mode {
        case let .scenarioOnly(scenario), let .campaignAndScenario(_, scenario):
            scenario
        case .campaignOnly:
            nil
        }
    }

    private func legacyLogText(_ row: GameLogRow) -> String? {
        guard case let .legacy(text, _) = row else { return nil }
        return text
    }

    private func encodedForceDrawValue(in envelope: GetGameEnvelope) throws -> JSONValue {
        let value = try ContractJSON.decode(JSONValue.self, from: ContractJSON.encode(envelope))
        guard case let .object(root) = value,
              case let .object(game)? = root["game"],
              case let .object(mode)? = game["mode"],
              case let .object(scenario)? = mode["That"],
              case let .object(chaosBag)? = scenario["chaosBag"],
              let forceDraw = chaosBag["forceDraw"]
        else { throw MutationError.unexpectedShape }
        return forceDraw
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
