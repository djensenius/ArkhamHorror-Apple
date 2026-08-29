@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Decodes the exact, non-empty production `get-game`/`game-update` fixtures (pinned to
/// backend commit `7611b60abc1f0107abfba2c1939e4d170e20d948`, schema revision `0.1.20`)
/// through production `ContractJSON`, and asserts the REST and WebSocket envelopes decode
/// to an equal ``PublicGameSnapshot`` plus representative nonempty maps/entities/mode/
/// turn/counters, matching this contract slice's core invariant.
@Suite("PublicGameSnapshot fixture decode")
struct PublicGameSnapshotFixtureTests {
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

    private func loadGetGame() throws -> GetGameEnvelope {
        try ContractJSON.decode(GetGameEnvelope.self, from: fixtureData(named: "get-game"))
    }

    private func loadGameUpdate() throws -> BoardSnapshotUpdate {
        try ContractJSON.decode(BoardSnapshotUpdate.self, from: fixtureData(named: "game-update"))
    }

    @Test("The REST GetGame and WebSocket GameUpdate envelopes decode to an equal snapshot")
    func restAndWebSocketSnapshotsAreEqual() throws {
        let getGame = try loadGetGame()
        let update = try loadGameUpdate()
        guard case let .snapshot(fromUpdate) = update else {
            Issue.record("Expected a .snapshot GameUpdate")
            return
        }
        #expect(getGame.game == fromUpdate)
    }

    @Test("GetGameEnvelope's top-level fields decode exactly")
    func getGameEnvelopeTopLevelFields() throws {
        let getGame = try loadGetGame()
        #expect(getGame.playerID?.rawValue.uuidString == "00000000-0000-0000-0000-000000000001")
        #expect(getGame.multiplayerMode == .solo)
        #expect(getGame.game.name == "Contract fixture game")
        #expect(getGame.game.id.rawValue.uuidString == "00000000-0000-0000-0000-000000000003")
    }

    @Test("The snapshot's nonempty locations/investigators/acts/agendas maps decode")
    func nonemptyEntityMapsDecode() throws {
        let game = try loadGetGame().game
        #expect(game.locations.count == 1)
        #expect(game.investigators.count == 1)
        #expect(game.acts.count == 1)
        #expect(game.agendas.count == 1)
        #expect(game.otherInvestigators.isEmpty)
        #expect(game.killedInvestigators.isEmpty)

        let locationID = try LocationID(
            #require(UUID(uuidString: "d5a66e84-c729-4066-8475-d8a155609025"))
        )
        guard case let .ordinary(location) = try #require(game.locations[locationID]) else {
            Issue.record("Expected an .ordinary location")
            return
        }
        #expect(location.label == "study")
        #expect(location.symbol == .circle)
        #expect(location.revealed)
        #expect(location.investigators.map(\.description) == ["c01001"])

        let investigatorID = try InvestigatorID(CardCode("c01001"))
        let investigator = try #require(game.investigators[investigatorID])
        #expect(investigator.name == CardName(title: "Roland Banks", subtitle: "The Fed"))
        #expect(investigator.investigatorClass == .guardian)
        #expect(investigator.health == 9)

        let actID = try ActID(CardCode("c01108"))
        let act = try #require(game.acts[actID])
        #expect(act.sequence == ActSequence(step: 1, side: .sideA))
        let cost = try #require(act.advanceCost)
        #expect(cost.tag == "GroupClueCost")

        let agendaID = try AgendaID(CardCode("c01105"))
        let agenda = try #require(game.agendas[agendaID])
        #expect(agenda.sequence == AgendaSequence(side: .sideA, step: 1))
        #expect(agenda.doomThreshold == .staticValue(3))
    }

    @Test("The snapshot's mode/turn/chaos-bag/counters decode representatively")
    func modeAndCountersDecodeRepresentatively() throws {
        let game = try loadGetGame().game
        guard case let .scenarioOnly(scenario) = game.mode else {
            Issue.record("Expected a .scenarioOnly mode")
            return
        }
        #expect(scenario.turn == 1)
        #expect(scenario.difficulty == .easy)
        #expect(try scenario.id == CardCode("c01104"))
        #expect(scenario.name == CardName(title: "The Gathering", subtitle: nil))
        #expect(scenario.chaosBag.chaosTokens.count == 16)
        #expect(scenario.decksLayout == ["agenda1 act1"])

        #expect(game.totalDoom == 0)
        #expect(game.totalClues == 0)
        #expect(game.scenarioSteps == 3)
        #expect(game.phase == .investigation)
        #expect(game.gameState == .active)
        #expect(game.playerCount == 1)
        #expect(try game.activeInvestigatorID == InvestigatorID(CardCode("c01001")))
        #expect(game.enemyAttackTargets.isEmpty)
        #expect(game.question.count == 1)
    }

    @Test("The snapshot's phaseStep decodes to the exact investigation sub-step")
    func phaseStepDecodesExactly() throws {
        let game = try loadGetGame().game
        #expect(game.phaseStep == .investigation(.investigatorTakesAction))
    }

    // MARK: - Aggregate semantic round-trip

    @Test("Decode→encode→reparse of get-game is semantically equal JSON, not just byte-order")
    func getGameSemanticJSONRoundTrips() throws {
        let original = try fixtureData(named: "get-game")
        let originalValue = try LosslessJSONParser.parse(original)
        let envelope = try ContractJSON.decode(GetGameEnvelope.self, from: original)
        let reencoded = try ContractJSON.encode(envelope)
        let reencodedValue = try LosslessJSONParser.parse(reencoded)
        // Comparing parsed `JSONValue` trees (object members are an unordered
        // `[String: JSONValue]`) rather than raw bytes tolerates re-encoding's different
        // key order while still comparing every leaf value exactly — including string
        // case — so a UUID leaf or map key that silently re-encoded with different case
        // than the original wire bytes would make this comparison fail.
        #expect(originalValue == reencodedValue)
    }

    @Test("Decode→encode→reparse of game-update is semantically equal JSON, not just byte-order")
    func gameUpdateSemanticJSONRoundTrips() throws {
        let original = try fixtureData(named: "game-update")
        let originalValue = try LosslessJSONParser.parse(original)
        let update = try ContractJSON.decode(BoardSnapshotUpdate.self, from: original)
        let reencoded = try ContractJSON.encode(update)
        let reencodedValue = try LosslessJSONParser.parse(reencoded)
        #expect(originalValue == reencodedValue)
    }

    // MARK: - Aggregate mutation regressions

    @Test("A genuinely missing phaseStep key fails aggregate decode for both REST and WS")
    func missingPhaseStepKeyFailsForBothEnvelopes() throws {
        let phaseStepBlock = """
            "phaseStep": {
              "tag": "InvestigationPhaseStep",
              "contents": "InvestigatorTakesActionStep"
            },

        """
        let getGameFixture = try #require(
            String(data: fixtureData(named: "get-game"), encoding: .utf8)
        )
        #expect(getGameFixture.contains(phaseStepBlock))
        let mutatedGetGame = getGameFixture.replacingOccurrences(of: phaseStepBlock, with: "")
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(GetGameEnvelope.self, from: Data(mutatedGetGame.utf8))
        }

        let gameUpdateFixture = try #require(
            String(data: fixtureData(named: "game-update"), encoding: .utf8)
        )
        #expect(gameUpdateFixture.contains(phaseStepBlock))
        let mutatedGameUpdate = gameUpdateFixture.replacingOccurrences(
            of: phaseStepBlock, with: ""
        )
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(
                BoardSnapshotUpdate.self, from: Data(mutatedGameUpdate.utf8)
            )
        }
    }

    @Test("An uppercase-rendered locations map key fails aggregate decode")
    func uppercaseLocationsMapKeyFailsAggregate() throws {
        var fixture = try #require(
            String(data: fixtureData(named: "get-game"), encoding: .utf8)
        )
        let lowercaseKey = "d5a66e84-c729-4066-8475-d8a155609025"
        #expect(fixture.contains("\"\(lowercaseKey)\":"))
        fixture = fixture.replacingOccurrences(
            of: "\"\(lowercaseKey)\":", with: "\"\(lowercaseKey.uppercased())\":"
        )
        #expect(throws: DecodingError.self) {
            _ = try ContractJSON.decode(GetGameEnvelope.self, from: Data(fixture.utf8))
        }
    }
}
