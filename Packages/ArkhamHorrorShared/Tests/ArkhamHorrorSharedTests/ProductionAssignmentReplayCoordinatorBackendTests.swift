@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Production assignment replay import response")
struct AssignmentReplayImportResponseTests {
    @Test("Checkpoint import omits the ordinary-export multiplayer override")
    func checkpointImportURLHasNoVariantOverride() throws {
        let profile = try ServerProfile.custom(
            id: #require(
                UUID(
                    uuidString:
                    "00000000-0000-0000-0000-000000000777"
                )
            ),
            displayName: "Production assignment replay",
            rawURL: "http://127.0.0.1:3002"
        )
        let url = ProductionAssignmentReplayBackend.importURL(profile: profile)
        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )

        #expect(components.path == "/api/v1/arkham/games/import")
        #expect(components.query == nil)
        #expect(components.queryItems == nil)
    }

    @Test("Governed production PublicGame fixture returns its canonical game ID")
    func governedPublicGameDecodes() throws {
        let response = try governedPublicGameData()
        let gameID = try ProductionAssignmentReplayBackend
            .decodeImportedGameID(from: response)
        #expect(
            gameID.rawValue.uuidString.lowercased()
                == "00000000-0000-0000-0000-000000000003"
        )
    }

    @Test("ID-only and malformed game identities fail closed")
    func malformedIdentityRejected() throws {
        let idOnly = Data(
            #"{"id":"00000000-0000-0000-0000-000000000003"}"#.utf8
        )
        #expect(
            throws: ProductionAssignmentReplayCoordinatorError
                .importedGameMalformed
        ) {
            _ = try ProductionAssignmentReplayBackend
                .decodeImportedGameID(from: idOnly)
        }

        var game = try governedPublicGameObject()
        game["id"] = .string("not-a-canonical-game-id")
        #expect(
            throws: ProductionAssignmentReplayCoordinatorError
                .importedGameMalformed
        ) {
            _ = try ProductionAssignmentReplayBackend
                .decodeImportedGameID(
                    from: ContractJSON.encode(JSONValue.object(game))
                )
        }
    }

    @Test("Unknown import response fields fail semantic round-trip validation")
    func unknownFieldRejected() throws {
        var game = try governedPublicGameObject()
        game["unexpectedImportField"] = .bool(true)
        #expect(
            throws: ProductionAssignmentReplayCoordinatorError
                .importedGameMalformed
        ) {
            _ = try ProductionAssignmentReplayBackend
                .decodeImportedGameID(
                    from: ContractJSON.encode(JSONValue.object(game))
                )
        }
    }

    @Test("Import snapshot decoding obeys its bounded response ceiling")
    func oversizedResponseRejected() throws {
        let response = try governedPublicGameData()
        #expect(
            throws: ProductionAssignmentReplayCoordinatorError
                .importedGameMalformed
        ) {
            _ = try ProductionAssignmentReplayBackend
                .decodeImportedGameID(
                    from: response,
                    maxByteCount: response.count - 1
                )
        }
        #expect(
            ProductionAssignmentReplayBackend.maximumImportResponseBytes
                == 64 * 1024 * 1024
        )
    }

    private func governedPublicGameData() throws -> Data {
        try ContractJSON.encode(
            JSONValue.object(governedPublicGameObject())
        )
    }

    private func governedPublicGameObject() throws -> [String: JSONValue] {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "get-game",
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        let envelope = try LosslessJSONParser.parse(
            Data(contentsOf: fixtureURL)
        )
        guard case let .object(root) = envelope,
              case let .object(game)? = root["game"]
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .importedGameMalformed
        }
        return game
    }
}
