@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Schema 0.1.57 repin (backend `4db99461`, the upstream sync, djensenius/ArkhamHorror#247):
/// the governed `Fixtures/Contract` board, socket and presentation bytes added by 0.1.57
/// still decode with the client's types. Those bytes are unchanged at the 0.1.63 pin; the
/// pin, capabilities and attestation revisions are covered by `Schema163ContractDriftTests`.
@Suite("Schema 0.1.57 contract drift")
struct Schema157ContractDriftTests {
    @Test("Vendored 0.1.57 board and socket fixtures decode")
    func boardAndSocketFixturesDecode() throws {
        let game = try ContractJSON.decode(GetGameEnvelope.self, from: data("get-game")).game
        #expect(game.settings.customRandomWeaknessPools?.isEmpty == true)
        let update = try ContractJSON.decode(BoardSnapshotUpdate.self, from: data("game-update"))
        guard case .snapshot = update else {
            Issue.record("game-update is not a snapshot: \(update)")
            return
        }
        let list = try ContractJSON.decode(GameList.self, from: data("game-list"))
        #expect(!list.isEmpty)
        for name in ["mode-turn-zero", "mode-campaign-scenario"] {
            _ = try ContractJSON.decode(GameMode.self, from: data(name))
        }
        _ = try ContractJSON.decode(
            Investigator.self, from: data("investigator-unhealed-horror-negative")
        )
        for name in ["game-watcher-count", "game-unarchived", "game-unarchive-failed"] {
            let message = try ContractJSON.decode(BoardSnapshotUpdate.self, from: data(name))
            guard case .unsupportedMessage = message else {
                Issue.record("\(name) did not decode as an unsupported message: \(message)")
                continue
            }
        }
    }

    @Test("Vendored 0.1.57 representatives include the two new presentations")
    func representativesDecode() throws {
        guard case let .object(root) = try value("question-presentation-representatives"),
              case let .array(entries)? = root["presentations"]
        else {
            Issue.record("representatives are not an object with a presentations array")
            return
        }
        #expect(entries.count == 39)
        for entry in entries {
            guard case let .object(fields) = entry, let presentation = fields["presentation"]
            else {
                Issue.record("malformed representative entry")
                continue
            }
            _ = try ContractJSON.decode(
                QuestionPresentation.self, from: LosslessJSONSerializer.serialize(presentation)
            )
        }
    }

    private func data(_ name: String) throws -> Data {
        try ContractFixtures.contractData(name)
    }

    private func value(_ name: String) throws -> JSONValue {
        try LosslessJSONParser.parse(data(name))
    }
}
