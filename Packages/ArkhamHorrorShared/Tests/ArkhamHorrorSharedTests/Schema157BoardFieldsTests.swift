@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Schema 0.1.57 added optional board fields: `settingsCustomRandomWeaknessPools`, the
/// investigator `playProhibitions`/`commitProhibitions`/`cannotDiscoverClues`/
/// `cannotSpendClues`, the chaos bag's `debugRevealedChaosTokens`, the scenario's
/// `sealedChaosTokens`, and the game and game-list `outcome`. These tests decode the
/// captured sync-candidate bytes in `Fixtures/Schema157Drift` and prove re-encoding keeps
/// every key, while pre-0.1.57 bytes (which omit them) still decode and re-encode exactly.
@Suite("Schema 0.1.57 board fields")
struct Schema157BoardFieldsTests {
    @Test("Captured 0.1.57 get-game re-encodes to semantically equal JSON")
    func getGameRoundTrips() throws {
        let original = try Schema157Fixtures.data("get-game")
        let envelope = try ContractJSON.decode(GetGameEnvelope.self, from: original)
        try expectSemanticRoundTrip(original, ContractJSON.encode(envelope))
    }

    @Test("Captured 0.1.57 game-update re-encodes to semantically equal JSON")
    func gameUpdateRoundTrips() throws {
        let original = try Schema157Fixtures.data("game-update")
        let update = try ContractJSON.decode(BoardSnapshotUpdate.self, from: original)
        try expectSemanticRoundTrip(original, ContractJSON.encode(update))
    }

    @Test("Captured 0.1.57 game-list re-encodes to semantically equal JSON")
    func gameListRoundTrips() throws {
        let original = try Schema157Fixtures.data("game-list")
        let list = try ContractJSON.decode(GameList.self, from: original)
        try expectSemanticRoundTrip(original, ContractJSON.encode(list))
    }

    @Test("Captured 0.1.57 modes re-encode to semantically equal JSON")
    func modesRoundTrip() throws {
        for name in ["mode-turn-zero", "mode-campaign-scenario"] {
            let original = try Schema157Fixtures.data(name)
            let mode = try ContractJSON.decode(GameMode.self, from: original)
            try expectSemanticRoundTrip(original, ContractJSON.encode(mode))
        }
    }

    @Test("Captured 0.1.57 investigator re-encodes to semantically equal JSON")
    func investigatorRoundTrips() throws {
        let original = try Schema157Fixtures.data("investigator-unhealed-horror-negative")
        let investigator = try ContractJSON.decode(Investigator.self, from: original)
        try expectSemanticRoundTrip(original, ContractJSON.encode(investigator))
    }

    // MARK: - Decoded values

    @Test("Captured 0.1.57 fields decode to their present-but-empty or null states")
    func capturedFieldsDecode() throws {
        let game = try ContractJSON.decode(
            GetGameEnvelope.self, from: Schema157Fixtures.data("get-game")
        ).game
        let investigator = try #require(game.investigators.values.first)
        let scenario = try #require(Schema157BoardFixtures.scenario(in: game.mode))
        #expect(game.outcome == .some(nil))
        #expect(game.settings.customRandomWeaknessPools?.isEmpty == true)
        #expect(game.gameSettings.customRandomWeaknessPools?.isEmpty == true)
        #expect(investigator.playProhibitions == [])
        #expect(investigator.commitProhibitions == [])
        #expect(investigator.cannotDiscoverClues == .some(nil))
        #expect(investigator.cannotSpendClues == .some(nil))
        #expect(scenario.chaosBag.debugRevealedChaosTokens == [])
        #expect(scenario.sealedChaosTokens == [])
    }

    @Test("Captured 0.1.57 game-list outcomes decode as null, recorded, or absent")
    func capturedGameListOutcomes() throws {
        let list = try ContractJSON.decode(GameList.self, from: Schema157Fixtures.data("game-list"))
        let outcomes = list.map { entry -> GameOutcome?? in
            guard case let .game(summary) = entry else { return nil }
            return summary.outcome
        }
        let won = GameOutcome(
            result: .won,
            certainty: .certain,
            note: nil,
            ending: GameOutcomeEnding(scenario: "c01104", resolution: .resolution(1)),
            source: .recorded
        )
        #expect(outcomes == [.some(nil), .some(nil), .some(nil), .some(won), nil])
    }

    @Test("Pre-0.1.57 bytes decode with every new field absent")
    func legacyBytesLeaveFieldsAbsent() throws {
        let game = try ContractJSON.decode(
            GetGameEnvelope.self, from: Schema157Fixtures.legacyData("get-game")
        ).game
        let investigator = try #require(game.investigators.values.first)
        let scenario = try #require(Schema157BoardFixtures.scenario(in: game.mode))
        #expect(game.outcome == nil)
        #expect(game.settings.customRandomWeaknessPools == nil)
        #expect(investigator.playProhibitions == nil)
        #expect(investigator.commitProhibitions == nil)
        #expect(investigator.cannotDiscoverClues == nil)
        #expect(investigator.cannotSpendClues == nil)
        #expect(scenario.chaosBag.debugRevealedChaosTokens == nil)
        #expect(scenario.sealedChaosTokens == nil)
        let list = try ContractJSON.decode(
            GameList.self, from: Schema157Fixtures.legacyData("game-list")
        )
        for entry in list {
            if case let .game(summary) = entry {
                #expect(summary.outcome == nil)
            }
        }
    }

    @Test("Populated 0.1.57 values decode and round-trip without loss")
    func populatedValuesRoundTrip() throws {
        let edits = Schema157BoardFixtures.populatedEdits
        let original = try Schema157BoardFixtures.mutatedGetGame(edits)
        let envelope = try ContractJSON.decode(GetGameEnvelope.self, from: original)
        let game = envelope.game
        let investigator = try #require(game.investigators.values.first)
        let scenario = try #require(Schema157BoardFixtures.scenario(in: game.mode))
        let pool = try #require(game.settings.customRandomWeaknessPools?.values.first)
        #expect(pool == CustomRandomWeaknessPool(enabled: true, cardCodes: ["01096", "01097"]))
        #expect(investigator.playProhibitions?.first?.sources.first?.name == "Frozen in Fear")
        #expect(investigator.commitProhibitions?.first?.sources == [])
        #expect(investigator.cannotDiscoverClues??.first?.kind.rawValue == "RefTreachery")
        #expect(investigator.cannotSpendClues == .some([]))
        #expect(scenario.chaosBag.debugRevealedChaosTokens?.first?.value == -2)
        #expect(scenario.chaosBag.debugRevealedChaosTokens?.first?.autoFail == false)
        #expect(scenario.sealedChaosTokens?.first?.chaosTokenFace == .minusTwo)
        #expect(game.outcome??.ending?.resolution == .noResolution)
        #expect(game.outcome??.certainty == .uncertain)
        try expectSemanticRoundTrip(original, ContractJSON.encode(envelope))
    }

    // MARK: - Malformed values

    @Test(
        "A malformed new value fails the snapshot at that field",
        arguments: [
            (
                "prohibition-arity",
                #"["investigators","c01001","playProhibitions"]"#,
                #"[["9b2e2a4c-1f6b-4b8e-9a59-2f1f3b2c9d10",[],[]]]"#
            ),
            (
                "prohibition-card-id",
                #"["investigators","c01001","commitProhibitions"]"#,
                #"[["not-a-uuid",[]]]"#
            ),
            ("discover-type", #"["investigators","c01001","cannotDiscoverClues"]"#, "true"),
            ("prohibitions-null", #"["investigators","c01001","playProhibitions"]"#, "null"),
            (
                "pool-key",
                #"["settings","settingsCustomRandomWeaknessPools"]"#,
                #"{"NOT-A-UUID":[true,[]]}"#
            ),
            (
                "pool-arity",
                #"["gameSettings","settingsCustomRandomWeaknessPools"]"#,
                #"{"00000000-0000-0000-0000-000000000001":[true]}"#
            ),
            (
                "debug-token",
                #"["mode","That","chaosBag","debugRevealedChaosTokens"]"#,
                #"[{"value":null,"autoFail":true,"autoSuccess":false}]"#
            ),
            ("sealed-null", #"["mode","That","sealedChaosTokens"]"#, "null"),
            (
                "outcome-result",
                #"["outcome"]"#,
                #"{"result":1,"certainty":"Certain","note":null,"ending":null,"source":"Recorded"}"#
            ),
            (
                "outcome-resolution",
                #"["outcome"]"#,
                #"{"result":"Won","certainty":"Certain","note":null,"#
                    + #""ending":{"scenario":"c01104","resolution":{"tag":"Maybe"}},"#
                    + #""source":"Recorded"}"#
            ),
        ]
    )
    func malformedValueFails(name _: String, pathJSON: String, valueJSON: String) throws {
        let path = try Schema157BoardFixtures.path(pathJSON)
        let lastKey = try #require(path.last)
        let data = try Schema157BoardFixtures.mutatedGetGame([(path, valueJSON)])
        #expect {
            try ContractJSON.decode(GetGameEnvelope.self, from: data)
        } throws: { error in
            "\(error)".contains(lastKey)
        }
    }

    @Test("A malformed off-board investigator is dropped on its own, like other drift there")
    func malformedOffBoardInvestigatorIsDroppedPerEntry() throws {
        let gameValue = try Schema157Fixtures.value("get-game")
        guard case let .object(root) = gameValue,
              case let .object(game)? = root["game"],
              case let .object(investigators)? = game["investigators"],
              case var .object(investigator)? = investigators["c01001"]
        else { throw Schema157Fixtures.Failure.shape }
        investigator["playProhibitions"] = .string("not-an-array")
        let other = JSONValue.object(["c01001": .object(investigator)])
        let data = try ContractJSON.encode(
            Schema157BoardFixtures.setting(other, at: ["game", "otherInvestigators"], in: gameValue)
        )
        let snapshot = try ContractJSON.decode(GetGameEnvelope.self, from: data).game
        #expect(snapshot.otherInvestigators.isEmpty)
        #expect(snapshot.investigators.count == 1)
    }

    @Test("A malformed game-list outcome fails that entry with its own error")
    func malformedGameListOutcomeFailsEntry() {
        let json = """
        {"id": "00000000-0000-0000-0000-000000000099", "scenario": null, "campaign": null,
         "gameState": {"tag": "IsActive"}, "name": "n", "investigators": [],
         "otherInvestigators": [], "multiplayerVariant": "Solo", "hasOpenSeats": false,
         "outcome": "Won"}
        """
        #expect {
            try ContractJSON.decode(GameListEntry.self, from: Data(json.utf8))
        } throws: { error in
            "\(error)".contains("outcome")
        }
    }

    // MARK: - Helpers

    private func expectSemanticRoundTrip(
        _ original: Data,
        _ reencoded: Data,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let differences = try Schema157BoardFixtures.differingPaths(
            LosslessJSONParser.parse(original),
            LosslessJSONParser.parse(reencoded),
            path: "$"
        )
        #expect(differences.isEmpty, "\(differences.prefix(20))", sourceLocation: sourceLocation)
    }
}

/// Shared helpers for the 0.1.57 board-field and socket drift tests.
enum Schema157BoardFixtures {
    /// Lists every JSON path whose value differs, so a dropped key names itself.
    static func differingPaths(_ lhs: JSONValue, _ rhs: JSONValue, path: String) -> [String] {
        switch (lhs, rhs) {
        case let (.object(left), .object(right)):
            Set(left.keys).union(right.keys).sorted().flatMap { key -> [String] in
                guard let leftValue = left[key], let rightValue = right[key] else {
                    return ["\(path).\(key) present on one side only"]
                }
                return differingPaths(leftValue, rightValue, path: "\(path).\(key)")
            }
        case let (.array(left), .array(right)) where left.count == right.count:
            zip(left, right).enumerated().flatMap { index, pair in
                differingPaths(pair.0, pair.1, path: "\(path)[\(index)]")
            }
        default:
            lhs == rhs ? [] : ["\(path) differs"]
        }
    }

    static func scenario(in mode: GameMode) -> Scenario? {
        switch mode {
        case let .scenarioOnly(scenario), let .campaignAndScenario(_, scenario):
            scenario
        case .campaignOnly:
            nil
        }
    }

    static let populatedEdits: [([String], String)] = [
        (
            ["settings", "settingsCustomRandomWeaknessPools"],
            #"{"00000000-0000-0000-0000-000000000001":[true,["01096","01097"]]}"#
        ),
        (
            ["investigators", "c01001", "playProhibitions"],
            #"[["9b2e2a4c-1f6b-4b8e-9a59-2f1f3b2c9d10",[{"kind":"RefTreachery","#
                + #""name":"Frozen in Fear","cardCode":"c01164","#
                + #""cardId":"5c3b7a1e-8d2f-4e6a-b1c9-0f2e4d6a8b3c","#
                + #""entityId":"5c3b7a1e-8d2f-4e6a-b1c9-0f2e4d6a8b3c","faceDown":false}]]]"#
        ),
        (
            ["investigators", "c01001", "commitProhibitions"],
            #"[["9b2e2a4c-1f6b-4b8e-9a59-2f1f3b2c9d10",[]]]"#
        ),
        (
            ["investigators", "c01001", "cannotDiscoverClues"],
            #"[{"kind":"RefTreachery","name":"Obscuring Fog","cardCode":"c01168","#
                + #""cardId":null,"entityId":null,"faceDown":false}]"#
        ),
        (["investigators", "c01001", "cannotSpendClues"], "[]"),
        (
            ["mode", "That", "chaosBag", "debugRevealedChaosTokens"],
            #"[{"token":{"chaosTokenCancelled":false,"chaosTokenFace":"MinusTwo","#
                + #""chaosTokenId":"22e6cf42-cc5c-4a9c-b9d1-f71e594e0d60","#
                + #""chaosTokenRevealedBy":null,"chaosTokenSealed":false},"#
                + #""value":-2,"autoFail":false,"autoSuccess":false}]"#
        ),
        (
            ["mode", "That", "sealedChaosTokens"],
            #"[{"chaosTokenCancelled":false,"chaosTokenFace":"MinusTwo","#
                + #""chaosTokenId":"22e6cf42-cc5c-4a9c-b9d1-f71e594e0d60","#
                + #""chaosTokenRevealedBy":null,"chaosTokenSealed":true}]"#
        ),
        (
            ["outcome"],
            #"{"result":"Lost","certainty":"Uncertain","note":"someNote","#
                + #""ending":{"scenario":"c01104","resolution":{"tag":"NoResolution"}},"#
                + #""source":"Inferred"}"#
        ),
    ]

    /// Applies `(path under "game", JSON literal)` edits to the captured 0.1.57 get-game.
    static func mutatedGetGame(_ edits: [([String], String)]) throws -> Data {
        var root = try Schema157Fixtures.value("get-game")
        for (path, json) in edits {
            root = try setting(
                LosslessJSONParser.parse(Data(json.utf8)), at: ["game"] + path, in: root
            )
        }
        return try ContractJSON.encode(root)
    }

    static func setting(
        _ value: JSONValue,
        at path: [String],
        in root: JSONValue
    ) throws -> JSONValue {
        guard let key = path.first else { return value }
        guard case var .object(object) = root, let child = object[key] else {
            throw Schema157Fixtures.Failure.shape
        }
        object[key] = try setting(value, at: Array(path.dropFirst()), in: child)
        return .object(object)
    }

    static func path(_ json: String) throws -> [String] {
        guard case let .array(items) = try LosslessJSONParser.parse(Data(json.utf8)) else {
            throw Schema157Fixtures.Failure.shape
        }
        return try items.map { item in
            guard case let .string(key) = item else { throw Schema157Fixtures.Failure.shape }
            return key
        }
    }
}
