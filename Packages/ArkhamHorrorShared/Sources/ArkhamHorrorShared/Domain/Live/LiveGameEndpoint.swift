import Foundation

/// Builds the live-game WebSocket upgrade URL for a game.
///
/// The backend serves the WebSocket upgrade from the *exact same* route as the REST
/// single-game fetch (`GET /arkham/games/:id`): its Yesod handler calls
/// `webSocketsOptions` before running the ordinary REST response body, so there is no
/// separate WebSocket path to construct. This type therefore reuses
/// ``GameLifecycleService/gameURL(_:suffix:on:pin:)`` unchanged for the path/host/
/// percent-encoding, and only additionally rewrites the scheme (`https`→`wss`,
/// `http`→`ws`) and appends the bearer token as a `?token=` query item.
///
/// Query-token (rather than an `Authorization` header) is used deliberately to match
/// today's real, production-proven backend/web-client behavior: a plain WebSocket
/// handshake cannot set a custom header, so the backend's own `Auth/JWT.hs` falls
/// back to a `token` query parameter specifically to support this. Every other
/// authenticated endpoint in this client uses the `Authorization` header (see
/// ``GameLifecycleService``); this is the one deliberate, narrowly-scoped exception,
/// centralized in this single function so a future header-based WebSocket auth
/// mechanism (if the backend ever adds one) requires changing exactly one place.
///
/// The resulting URL always embeds the bearer token as a query item. Per this
/// package's transport-security policy, it must never be logged, persisted, or
/// included in any diagnostic/error value -- see ``GameSocketConnectError`` and
/// ``GameSocketTransportError``, neither of which carries a URL or raw system
/// error description for exactly this reason.
enum LiveGameEndpoint {
    /// Builds the token-bearing WebSocket URL for `id` on `profile`.
    ///
    /// - Throws: ``GameLifecycleError/invalidPathSegment`` under the same
    ///   (practically unreachable, since every ``GameID`` is a `UUID`) conditions as
    ///   ``GameLifecycleService/gameURL(_:suffix:on:pin:)``, and
    ///   ``GameLifecycleError/nonHTTPResponse`` if `profile`'s scheme is neither
    ///   `http` nor `https` (defense in depth; ``ServerProfile`` validation already
    ///   guarantees one of those two).
    static func webSocketURL(
        for id: GameID, on profile: ServerProfile, token: String, pin: ContractPin = .current
    ) throws -> URL {
        let restURL = try GameLifecycleService.gameURL(id, on: profile, pin: pin)
        guard var components = URLComponents(url: restURL, resolvingAgainstBaseURL: false) else {
            throw GameLifecycleError.invalidPathSegment
        }
        switch components.scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            throw GameLifecycleError.nonHTTPResponse
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "token", value: token))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw GameLifecycleError.invalidPathSegment
        }
        return url
    }
}
