@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Schema 0.1.57 repin (backend `4db99461`, the upstream sync, djensenius/ArkhamHorror#247):
/// the governed `Fixtures/Contract` bytes vendored from that commit report 0.1.57, agree with
/// `ContractPin.current`, and decode with the client's types.
@Suite("Schema 0.1.57 contract drift")
struct Schema157ContractDriftTests {
    private static let revision = ContractRevision.literal(major: 0, minor: 1, patch: 57)

    @Test("ContractPin.current pins 0.1.57 and still accepts 0.1.48 servers")
    func pinRevisions() {
        let pin = ContractPin.current
        #expect(pin.backendCommit == "4db9946179ef8b7a242bd7e40c0a2d74990cf3e9")
        #expect(pin.supportedSchemaRevision == Self.revision)
        #expect(pin.sourceNativeClientMinimumRevision == Self.revision)
        #expect(pin.minimumServerSchemaRevision == .literal(major: 0, minor: 1, patch: 48))
        #expect(pin.expectedApiBasePath == "/api/v1")
    }

    @Test("Vendored 0.1.57 capabilities match the pin and evaluate as compatible")
    func capabilitiesMatchPin() throws {
        for name in ["capabilities", "capabilities-arkhamdb", "capabilities-locale-catalog"] {
            let caps = try ContractJSON.decode(ServerCapabilities.self, from: data(name))
            #expect(caps.schemaRevision == Self.revision, "\(name)")
            #expect(
                caps.nativeClientMinimumRevision
                    == ContractPin.current.sourceNativeClientMinimumRevision,
                "\(name)"
            )
            guard case .compatible = CompatibilityEvaluator(pin: .current).evaluate(caps) else {
                Issue.record("\(name) is not compatible with ContractPin.current")
                continue
            }
        }
    }

    @Test("The manifest and replay attestation record schema 0.1.57")
    func manifestAndAttestationRevisions() throws {
        guard case let .object(manifest) = try value("manifest") else {
            Issue.record("manifest.json is not an object")
            return
        }
        #expect(manifest["schemaRevision"] == .string("0.1.57"))
        let attested = try Self.values(forKey: "contractSchemaRevision", in: value(
            "replay-attestation"
        ))
        #expect(attested == [.string("0.1.57"), .string("0.1.57")])
    }

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
        try Schema157Fixtures.contractData(name)
    }

    private func value(_ name: String) throws -> JSONValue {
        try LosslessJSONParser.parse(data(name))
    }

    private static func values(forKey key: String, in value: JSONValue) -> [JSONValue] {
        switch value {
        case let .object(object):
            object.keys.sorted().flatMap { name -> [JSONValue] in
                let nested = object[name].map { values(forKey: key, in: $0) } ?? []
                return name == key ? [object[name]].compactMap(\.self) + nested : nested
            }
        case let .array(array):
            array.flatMap { values(forKey: key, in: $0) }
        default:
            []
        }
    }
}
