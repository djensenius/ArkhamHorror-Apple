@testable import ArkhamHorrorShared
import Foundation
import Testing

// MARK: - Tests

@Suite("GameLifecycleService")
struct GameLifecycleServiceTests {
    private let profile = ServerProfile.hosted
    private let token = "the-session-token"
    private let gameID = GameID(UUID(uuidString: "00000000-0000-0000-0000-000000000042")!)

    private func httpResponse(_ status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func emptyBody() -> Data {
        Data()
    }

    private func publicGameBody(tag: String = "PublicGame", id: String? = nil) -> Data {
        if let id {
            Data(
                """
                {"tag":"\(tag)","id":"\(id)","name":"Ignored","log":[],
                "locations":{},"investigators":{},"unknownBoardField":{"deeply":"nested"}}
                """.utf8
            )
        } else {
            Data(#"{"tag":"\#(tag)","error":"Ignored failure detail"}"#.utf8)
        }
    }

    private func loadFixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name, withExtension: "json", subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    // MARK: - listGames

    @Test("listGames issues a GET to the pin-derived /arkham/games URL with Authorization")
    func listGamesRequestShape() async throws {
        let url = profile.endpointURL(path: "/arkham/games")
        let transport = GameLifecycleRecordingTransport(
            data: Data("[]".utf8), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        _ = try await service.listGames(on: profile, token: token)
        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "GET")
        #expect(request?.url?.absoluteString == "https://arkhamhorror.app/api/v1/arkham/games")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Token \(token)")
        #expect(request?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request?.httpShouldHandleCookies == false)
        #expect(request?.httpBody == nil)
    }

    @Test("listGames decodes the original game-list.json fixture bytes through ContractJSON")
    func listGamesDecodesOriginalFixture() async throws {
        let fixture = try loadFixture("game-list")
        let url = profile.endpointURL(path: "/arkham/games")
        let transport = GameLifecycleRecordingTransport(
            data: fixture, response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let games = try await service.listGames(on: profile, token: token)
        #expect(games.count == 5)
        guard case let .game(summary) = games[0] else {
            Issue.record("Expected the first fixture row to decode as a game")
            return
        }
        #expect(summary.name == "Contract fixture game")
        guard case .failed = games[4] else {
            Issue.record("Expected the last fixture row to decode as a failed entry")
            return
        }
    }

    // MARK: - createGame

    @Test("createGame issues a POST to /arkham/games with Authorization and a JSON body")
    func createGameRequestShape() async throws {
        let url = profile.endpointURL(path: "/arkham/games")
        let responseID = "00000000-0000-0000-0000-000000000099"
        let transport = GameLifecycleRecordingTransport(
            data: publicGameBody(id: responseID), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let request = try sampleCreateGameRequest()
        let envelope = try await service.createGame(request, on: profile, token: token)
        let capturedRequest = await transport.capturedRequest
        #expect(capturedRequest?.httpMethod == "POST")
        #expect(
            capturedRequest?.url?.absoluteString == "https://arkhamhorror.app/api/v1/arkham/games"
        )
        #expect(capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Token \(token)")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(await transport.capturedBody)
        let decodedBody = try ContractJSON.decode(CreateGameRequest.self, from: body)
        #expect(decodedBody == request)
        #expect(try envelope == .game(GameID(#require(UUID(uuidString: responseID)))))
    }

    @Test("createGame's shallow envelope never requires decoding board-state fields")
    func createGameEnvelopeIgnoresBoardFields() async throws {
        // The response carries unrelated/unrecognized board keys
        // (`locations`/`investigators`/`unknownBoardField`) that this client must never
        // need to touch to extract the created game's id.
        let url = profile.endpointURL(path: "/arkham/games")
        let responseID = "00000000-0000-0000-0000-0000000000ab"
        let transport = GameLifecycleRecordingTransport(
            data: publicGameBody(id: responseID), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let envelope = try await service.createGame(
            sampleCreateGameRequest(), on: profile, token: token
        )
        #expect(try envelope == .game(GameID(#require(UUID(uuidString: responseID)))))
    }

    @Test("An unrecognized envelope tag decodes as .unsupported, never guessed at")
    func unrecognizedEnvelopeTagIsUnsupported() async throws {
        let url = profile.endpointURL(path: "/arkham/games")
        let transport = GameLifecycleRecordingTransport(
            data: publicGameBody(tag: "FailedToLoadGame"), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let envelope = try await service.createGame(
            sampleCreateGameRequest(), on: profile, token: token
        )
        #expect(envelope == .unsupported)
    }

    // MARK: - deleteGame

    // Production handler: `deleteApiV1ArkhamGameR :: ArkhamGameId -> Handler ()`.
    // Yesod's `ToTypedContent ()` always sends a genuine zero-byte body on success
    // (`toContent () = toContent B.empty`), matching the governed OpenAPI spec's
    // `200` response for `DELETE /arkham/games/{gameId}`, which declares no
    // `content:` schema. This must never be run through a JSON decoder.
    @Test("deleteGame issues a DELETE to /arkham/games/:id and accepts a zero-byte success body")
    func deleteGameRequestShape() async throws {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)")
        let transport = GameLifecycleRecordingTransport(
            data: emptyBody(), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        try await service.deleteGame(gameID, on: profile, token: token)
        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "DELETE")
        #expect(
            request?.url?.absoluteString
                == "https://arkhamhorror.app/api/v1/arkham/games/"
                + "00000000-0000-0000-0000-000000000042"
        )
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Token \(token)")
        #expect(request?.httpBody == nil)
    }

    @Test("deleteGame rejects an unexpected non-empty 2xx body as drift")
    func deleteGameRejectsNonEmptyBody() async {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)")
        let transport = GameLifecycleRecordingTransport(
            data: Data("[]".utf8), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        await #expect(throws: GameLifecycleError.malformedPayload) {
            try await service.deleteGame(gameID, on: profile, token: token)
        }
    }

    // MARK: - Lobby: join/peek/open-seats/claim-seat/decks

    @Test("peekLobby issues a GET to /arkham/games/:id/join")
    func peekLobbyRequestShape() async throws {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)/join")
        let transport = GameLifecycleRecordingTransport(
            data: publicGameBody(id: gameID.description), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let envelope = try await service.peekLobby(gameID, on: profile, token: token)
        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "GET")
        #expect(request?.url?.absoluteString.hasSuffix("/join") == true)
        #expect(envelope == .game(gameID))
    }

    @Test("joinGame issues a PUT to /arkham/games/:id/join")
    func joinGameRequestShape() async throws {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)/join")
        let transport = GameLifecycleRecordingTransport(
            data: publicGameBody(id: gameID.description), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        _ = try await service.joinGame(gameID, on: profile, token: token)
        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "PUT")
        #expect(
            request?.url?.absoluteString
                == "https://arkhamhorror.app/api/v1/arkham/games/"
                + "00000000-0000-0000-0000-000000000042/join"
        )
        #expect(request?.httpBody == nil)
    }

    @Test("openSeats issues a GET to /arkham/games/:id/open-seats and decodes the fixture bytes")
    func openSeatsRequestShapeAndFixture() async throws {
        let fixtureDocument = try loadFixture("game-lifecycle")
        let fixture = try ContractJSON.decode(
            GameLifecycleOpenSeatsFixture.self, from: fixtureDocument
        )
        let openSeatsBody = try ContractJSON.encode(fixture.openSeats)
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)/open-seats")
        let transport = GameLifecycleRecordingTransport(
            data: openSeatsBody, response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let seats = try await service.openSeats(for: gameID, on: profile, token: token)
        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "GET")
        #expect(request?.url?.absoluteString.hasSuffix("/open-seats") == true)
        #expect(seats == fixture.openSeats)
    }

    // MARK: - Fixtures

    private func sampleCreateGameRequest() throws -> CreateGameRequest {
        try CreateGameRequest(
            deckIds: [],
            playerCount: 1,
            campaignOrScenario: CampaignOrScenario(campaignId: nil, scenarioId: "01104"),
            difficulty: .easy,
            campaignName: "Test standalone",
            multiplayerVariant: .solo,
            includeTarotReadings: false,
            options: [],
            strictAsIfAt: .absent,
            asIfRuling: .absent,
            ultimatumsAndBoons: .absent,
            achievementsEnabled: .absent
        )
    }
}

/// Mirrors `GameLifecycleTests.swift`'s combined fixture-decode shape, scoped to just
/// the `openSeats` key this file needs.
private struct GameLifecycleOpenSeatsFixture: Decodable {
    let openSeats: OpenSeats
}
