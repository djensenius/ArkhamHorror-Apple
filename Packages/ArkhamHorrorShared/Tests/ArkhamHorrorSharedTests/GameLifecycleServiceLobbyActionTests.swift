@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Split out of `GameLifecycleServiceTests.swift` purely by struct-body length:
/// request-shape and empty-body-drift coverage for the `claim-seat`/`decks` mutation
/// endpoints, whose production handlers (`postApiV1ArkhamGameClaimSeatR`,
/// `putApiV1ArkhamGameDecksR`) both have a `Handler ()` return type -- see
/// `GameLifecycleServiceTests.swift`'s `deleteGame` section for the exact Yesod
/// zero-byte-body behavior this shares.
@Suite("GameLifecycleService — claim-seat/decks")
struct GameLifecycleServiceLobbyActionTests {
    private let profile = ServerProfile.hosted
    private let token = "the-session-token"
    private let gameID = GameID(UUID(uuidString: "00000000-0000-0000-0000-000000000042")!)

    private func httpResponse(_ status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func emptyBody() -> Data {
        Data()
    }

    /// Production handler: `postApiV1ArkhamGameClaimSeatR :: ArkhamGameId -> Handler ()`.
    /// Same zero-byte-on-success shape as deleteGame; see that section's comment.
    @Test("claimSeat issues a POST to /arkham/games/:id/claim-seat, accepting an empty body")
    func claimSeatRequestShape() async throws {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)/claim-seat")
        let transport = GameLifecycleRecordingTransport(
            data: emptyBody(), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let claim = try ClaimSeatRequest(investigatorId: InvestigatorCode("01001"))
        try await service.claimSeat(claim, in: gameID, on: profile, token: token)
        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "POST")
        #expect(request?.url?.absoluteString.hasSuffix("/claim-seat") == true)
        let body = try #require(await transport.capturedBody)
        #expect(body == Data(#"{"investigatorId":"01001"}"#.utf8))
        let decoded = try ContractJSON.decode(ClaimSeatRequest.self, from: body)
        #expect(decoded == claim)
    }

    @Test("claimSeat surfaces server-authored full-game and seat-taken errors verbatim")
    func claimSeatSurfacesServerAuthoredErrors() async throws {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)/claim-seat")
        let error = DeckOperationError(errorMsg: "That seat is already taken")
        let transport = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(error), response: httpResponse(403, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let claim = try ClaimSeatRequest(investigatorId: InvestigatorCode("01001"))

        await #expect(throws: GameLifecycleError.operationFailed(error)) {
            try await service.claimSeat(claim, in: gameID, on: profile, token: token)
        }
        #expect(GameLifecycleError.operationFailed(error).message == "That seat is already taken")
    }

    @Test("claimSeat rejects an unexpected non-empty 2xx body as drift")
    func claimSeatRejectsNonEmptyBody() async throws {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)/claim-seat")
        let transport = GameLifecycleRecordingTransport(
            data: Data(#"{"unexpected":true}"#.utf8), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let claim = try ClaimSeatRequest(investigatorId: InvestigatorCode("01001"))
        await #expect(throws: GameLifecycleError.malformedPayload) {
            try await service.claimSeat(claim, in: gameID, on: profile, token: token)
        }
    }

    /// Production handler: `putApiV1ArkhamGameDecksR :: ArkhamGameId -> Handler ()`.
    /// Same zero-byte-on-success shape as deleteGame; see that section's comment.
    @Test("chooseDeck issues a PUT to /arkham/games/:id/decks and accepts an empty success body")
    func chooseDeckRequestShape() async throws {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)/decks")
        let transport = GameLifecycleRecordingTransport(
            data: emptyBody(), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let choice = try ChooseDeckRequest(
            investigatorId: InvestigatorCode("01001"), deckUrl: nil, deckList: nil
        )
        try await service.chooseDeck(choice, in: gameID, on: profile, token: token)
        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "PUT")
        #expect(request?.url?.absoluteString.hasSuffix("/decks") == true)
        let body = try #require(await transport.capturedBody)
        #expect(body == Data(#"{"investigatorId":"01001"}"#.utf8))
        let decoded = try ContractJSON.decode(ChooseDeckRequest.self, from: body)
        #expect(decoded == choice)
    }

    @Test("chooseDeck sends deckUrl and deckList.url for arkham.build upgrades")
    func chooseDeckUpgradeRequestIncludesDeckListURL() async throws {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)/decks")
        let transport = GameLifecycleRecordingTransport(
            data: emptyBody(), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let deckURL = "https://api.arkham.build/v1/public/share/abc123"
        let deckList = try DeckListInput(
            slots: CardQuantityMapInput(["01002": 1]),
            sideSlots: .absent,
            investigatorCode: InvestigatorCode("01001"),
            investigatorName: nil,
            meta: nil,
            tabooId: nil,
            url: deckURL,
            id: nil,
            name: nil
        )
        let choice = try ChooseDeckRequest(
            investigatorId: InvestigatorCode("01001"), deckUrl: deckURL, deckList: deckList
        )
        try await service.chooseDeck(choice, in: gameID, on: profile, token: token)
        let body = try #require(await transport.capturedBody)
        let expectedBody = Data(
            """
            {"deckList":{\
            "investigator_code":"01001",\
            "slots":{"01002":1},\
            "url":"https://api.arkham.build/v1/public/share/abc123"\
            },"deckUrl":"https://api.arkham.build/v1/public/share/abc123",\
            "investigatorId":"01001"}
            """.utf8
        )
        #expect(body == expectedBody)
        let decoded = try ContractJSON.decode(ChooseDeckRequest.self, from: body)
        #expect(decoded == choice)
    }

    @Test("joinGame surfaces server-authored full-game errors verbatim")
    func joinGameSurfacesServerAuthoredErrors() async throws {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)/join")
        let error = DeckOperationError(errorMsg: "This game is full")
        let transport = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(error), response: httpResponse(403, url: url)
        )
        let service = GameLifecycleService(transport: transport)

        await #expect(throws: GameLifecycleError.operationFailed(error)) {
            _ = try await service.joinGame(gameID, on: profile, token: token)
        }
        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "PUT")
        #expect(request?.httpBody == nil)
        #expect(GameLifecycleError.operationFailed(error).message == "This game is full")
    }

    @Test("openSeats surfaces server-authored wrong-variant errors verbatim")
    func openSeatsSurfacesServerAuthoredErrors() async throws {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)/open-seats")
        let error = DeckOperationError(errorMsg: "This game is not a WithFriends lobby")
        let transport = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(error), response: httpResponse(400, url: url)
        )
        let service = GameLifecycleService(transport: transport)

        await #expect(throws: GameLifecycleError.operationFailed(error)) {
            _ = try await service.openSeats(for: gameID, on: profile, token: token)
        }
        let request = await transport.capturedRequest
        #expect(request?.httpMethod == "GET")
        #expect(request?.httpBody == nil)
        #expect(
            GameLifecycleError.operationFailed(error).message
                == "This game is not a WithFriends lobby"
        )
    }

    @Test("chooseDeck surfaces backend deck-update errors verbatim")
    func chooseDeckSurfacesBackendOperationError() async throws {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)/decks")
        let error = DeckOperationError(errorMsg: "server says the deck is invalid")
        let transport = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(error), response: httpResponse(400, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let choice = try ChooseDeckRequest(
            investigatorId: InvestigatorCode("01001"), deckUrl: nil, deckList: nil
        )
        await #expect(throws: GameLifecycleError.operationFailed(error)) {
            try await service.chooseDeck(choice, in: gameID, on: profile, token: token)
        }
        #expect(GameLifecycleError.operationFailed(error).message == error.errorMsg)
    }

    @Test("chooseDeck surfaces backend deck-update errors verbatim for status 500")
    func chooseDeckSurfacesBackendOperationErrorOnServerError() async throws {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)/decks")
        let error = DeckOperationError(errorMsg: "Could not upgrade deck: server details")
        let transport = try GameLifecycleRecordingTransport(
            data: ContractJSON.encode(error), response: httpResponse(500, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let choice = try ChooseDeckRequest(
            investigatorId: InvestigatorCode("01001"), deckUrl: nil, deckList: nil
        )
        await #expect(throws: GameLifecycleError.operationFailed(error)) {
            try await service.chooseDeck(choice, in: gameID, on: profile, token: token)
        }
        #expect(GameLifecycleError.operationFailed(error).message == error.errorMsg)
    }

    @Test("chooseDeck rejects an unexpected non-empty 2xx body as drift")
    func chooseDeckRejectsNonEmptyBody() async throws {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)/decks")
        let transport = GameLifecycleRecordingTransport(
            data: Data("[]".utf8), response: httpResponse(200, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let choice = try ChooseDeckRequest(
            investigatorId: InvestigatorCode("01001"), deckUrl: nil, deckList: nil
        )
        await #expect(throws: GameLifecycleError.malformedPayload) {
            try await service.chooseDeck(choice, in: gameID, on: profile, token: token)
        }
    }
}
