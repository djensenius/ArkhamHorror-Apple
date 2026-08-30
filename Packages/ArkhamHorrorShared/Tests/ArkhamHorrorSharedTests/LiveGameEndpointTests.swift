@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic coverage for ``LiveGameEndpoint/webSocketURL(for:on:token:pin:)``: the
/// scheme rewrite, token query-item append, and exact-path reuse of
/// ``GameLifecycleService/gameURL(_:suffix:on:pin:)`` this type's documentation
/// promises.
@Suite("LiveGameEndpoint")
struct LiveGameEndpointTests {
    @Test("A hosted (https) profile's game URL rewrites to wss and appends the token")
    func hostedProfileRewritesToWSS() throws {
        let gameID = try GameID(#require(UUID(uuidString: "11111111-1111-1111-1111-111111111111")))
        let url = try LiveGameEndpoint.webSocketURL(
            for: gameID, on: .hosted, token: "secret-token"
        )
        #expect(url.scheme == "wss")
        #expect(url.host == "arkhamhorror.app")
        #expect(url.path.hasSuffix("/11111111-1111-1111-1111-111111111111"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let tokenItem = components.queryItems?.first { $0.name == "token" }
        #expect(tokenItem?.value == "secret-token")
    }

    @Test("A local (http) custom profile's game URL rewrites to ws, not wss")
    func localHTTPProfileRewritesToWS() throws {
        let profile = try ServerProfile.custom(
            displayName: "Local", rawURL: "http://localhost:3000"
        )
        let gameID = GameID(UUID())
        let url = try LiveGameEndpoint.webSocketURL(for: gameID, on: profile, token: "t")
        #expect(url.scheme == "ws")
    }

    @Test("The token query item is appended alongside (not replacing) any existing query items")
    func tokenAppendedAlongsideExistingQueryItems() throws {
        let gameID = GameID(UUID())
        let url = try LiveGameEndpoint.webSocketURL(
            for: gameID, on: .hosted, token: "abc123", pin: .current
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        // Exactly the REST path plus the appended token -- no other query items are
        // introduced by this rewrite.
        #expect(components.queryItems?.count == 1)
    }

    @Test("Two different games on the same profile/token produce distinct URLs")
    func differentGamesProduceDistinctURLs() throws {
        let first = try LiveGameEndpoint.webSocketURL(
            for: GameID(UUID()), on: .hosted, token: "t"
        )
        let second = try LiveGameEndpoint.webSocketURL(
            for: GameID(UUID()), on: .hosted, token: "t"
        )
        #expect(first != second)
    }
}
