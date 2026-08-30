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
        let decoded = try ContractJSON.decode(ClaimSeatRequest.self, from: body)
        #expect(decoded == claim)
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
        let decoded = try ContractJSON.decode(ChooseDeckRequest.self, from: body)
        #expect(decoded == choice)
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
