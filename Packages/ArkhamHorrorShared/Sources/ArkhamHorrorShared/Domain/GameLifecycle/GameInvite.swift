import Foundation

/// A web-compatible multiplayer invite target for a game lobby.
///
/// The web client shares ordinary multiplayer lobbies as `/games/:id/join` when the
/// recipient needs to join the pending game, and as `/games/:id/claim-seat` when the
/// recipient should pick an open investigator seat. Native UI keeps the same route
/// spelling so copied links remain understandable across clients; parsing accepts a
/// full web URL or a raw UUID so a user can paste either form without the client
/// inventing any multiplayer rules.
struct GameInvite: Equatable, Sendable {
    enum Route: String, Sendable {
        case join
        case claimSeat = "claim-seat"
    }

    enum ParseError: Error, Equatable, Sendable {
        case empty
        case unsupported
    }

    let gameID: GameID
    let route: Route

    static func parse(_ rawValue: String) throws -> GameInvite {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }
        if let uuid = UUID(uuidString: trimmed) {
            return GameInvite(gameID: GameID(uuid), route: .join)
        }
        guard let components = URLComponents(string: trimmed) else {
            throw ParseError.unsupported
        }
        let scheme = components.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" || scheme == nil else {
            throw ParseError.unsupported
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let gamesIndex = parts.lastIndex(of: "games"),
              parts.indices.contains(gamesIndex + 1),
              let uuid = UUID(uuidString: parts[gamesIndex + 1])
        else { throw ParseError.unsupported }
        let routePart = parts.indices.contains(gamesIndex + 2) ? parts[gamesIndex + 2] : "join"
        guard let route = Route(rawValue: routePart), !parts.indices.contains(gamesIndex + 3)
        else { throw ParseError.unsupported }
        return GameInvite(gameID: GameID(uuid), route: route)
    }

    func webURL(on profile: ServerProfile) -> URL? {
        Self.webURL(for: gameID, route: route, on: profile)
    }

    static func webURL(for gameID: GameID, route: Route, on profile: ServerProfile) -> URL? {
        guard var components = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        let basePath = profile.baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let routePath = "games/\(gameID.rawValue.uuidString.lowercased())/\(route.rawValue)"
        components.path = ([basePath, routePath].filter { !$0.isEmpty }).joined(separator: "/")
        if !components.path.hasPrefix("/") {
            components.path = "/" + components.path
        }
        components.queryItems = nil
        components.fragment = nil
        return components.url
    }
}
