import Foundation

/// Recognizes the deck-import URL shapes the web client supports without letting the
/// native client turn `/fetch` into a general-purpose server-side URL fetcher.
enum DeckImportURL: Equatable, Sendable {
    case fetchURL(String)

    enum ParseError: Error, Equatable, Sendable {
        case invalid
        case unsupportedArkhamBuildShare
    }

    var fetchURL: String {
        switch self {
        case let .fetchURL(url):
            url
        }
    }

    static func parse(_ rawURL: String) throws -> DeckImportURL {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty
        else { throw ParseError.invalid }

        if isArkhamDBHost(host) {
            return try arkhamDBURL(from: components)
        }
        if host == "arkham.build" {
            return try arkhamBuildURL(from: components, original: trimmed)
        }
        throw ParseError.invalid
    }

    private static func isArkhamDBHost(_ host: String) -> Bool {
        host == "arkhamdb.com" || host.hasSuffix(".arkhamdb.com")
    }

    private static func arkhamDBURL(from components: URLComponents) throws -> DeckImportURL {
        let parts = pathParts(components)
        guard parts.count == 2 || parts.count == 3,
              ["deck", "decklist"].contains(parts[0])
        else { throw ParseError.invalid }
        let identifier: String
        if parts.count == 2 {
            identifier = parts[1]
        } else {
            guard parts[1] == "view" else { throw ParseError.invalid }
            identifier = parts[2]
        }
        guard !identifier.isEmpty else { throw ParseError.invalid }
        return .fetchURL("https://arkhamdb.com/api/public/\(parts[0])/\(identifier)")
    }

    private static func arkhamBuildURL(
        from components: URLComponents, original: String
    ) throws -> DeckImportURL {
        let parts = pathParts(components)
        if parts.count == 2, parts[0] == "decklist", !parts[1].isEmpty {
            return .fetchURL(original)
        }
        if parts.count == 3, parts[0] == "decklist", parts[1] == "view", !parts[2].isEmpty {
            return .fetchURL(original)
        }
        if parts.count == 2, ["share", "deck"].contains(parts[0]) {
            throw ParseError.unsupportedArkhamBuildShare
        }
        if parts.count == 3,
           parts[0] == "share" && parts[1] == "view"
           || parts[0] == "deck" && parts[1] == "view"
        {
            throw ParseError.unsupportedArkhamBuildShare
        }
        throw ParseError.invalid
    }

    private static func pathParts(_ components: URLComponents) -> [String] {
        components.path.split(separator: "/").map(String.init)
    }
}

extension DeckImportURL.ParseError {
    var message: String {
        switch self {
        case .invalid:
            "Enter an https ArkhamDB deck/decklist URL or arkham.build decklist URL."
        case .unsupportedArkhamBuildShare:
            "arkham.build share links are not supported yet. Paste an arkham.build decklist link."
        }
    }
}
