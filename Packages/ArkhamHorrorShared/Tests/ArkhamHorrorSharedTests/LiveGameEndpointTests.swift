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

    @Test("""
    The token is the only query item on the resulting URL, matching the REST \
    endpoint's own query-free construction
    """)
    func tokenIsTheOnlyQueryItem() throws {
        let gameID = GameID(UUID())
        let url = try LiveGameEndpoint.webSocketURL(
            for: gameID, on: .hosted, token: "abc123", pin: .current
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        // `ServerProfile` normalization always strips any query component from a
        // profile's own base URL (see `ServerProfile+Normalization.swift`), so no
        // `ServerProfile` this client can construct ever carries a pre-existing
        // query item into `gameURL(_:suffix:on:pin:)` for this appended token to
        // sit "alongside" -- this test instead proves the appended token is the
        // *only* query item ever produced by this rewrite, exactly as many query
        // items as the underlying REST URL itself has (none) plus the one token.
        #expect(components.queryItems?.count == 1)
        #expect(components.queryItems?.first?.name == "token")
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
