@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("GameLifecycleService — deck failures")
struct GameLifecycleServiceDeckFailureTests {
    private let profile = ServerProfile.hosted
    private let token = "the-session-token"
    private let gameID = GameID(UUID(uuidString: "00000000-0000-0000-0000-000000000042")!)

    private func httpResponse(_ status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    @Test("chooseDeck keeps generic Yesod 404 bodies localized")
    func chooseDeckKeepsGenericNotFoundLocalized() async throws {
        let url = profile.endpointURL(path: "/arkham/games/\(gameID.description)/decks")
        let transport = GameLifecycleRecordingTransport(
            data: Data(#"{"message":"Not Found"}"#.utf8),
            response: httpResponse(404, url: url)
        )
        let service = GameLifecycleService(transport: transport)
        let choice = try ChooseDeckRequest(
            investigatorId: InvestigatorCode("01001"), deckUrl: nil, deckList: nil
        )
        await #expect(throws: GameLifecycleError.unexpectedStatus(404)) {
            try await service.chooseDeck(choice, in: gameID, on: profile, token: token)
        }
        #expect(
            GameLifecycleError.unexpectedStatus(404).message
                == "This game is no longer available."
        )
    }
}
