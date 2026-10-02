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
        if host == "arkham.build" || host == "api.arkham.build" {
            return try arkhamBuildURL(from: components, host: host)
        }
        throw ParseError.invalid
    }

    private static func isArkhamDBHost(_ host: String) -> Bool {
        host == "arkhamdb.com" || host.hasSuffix(".arkhamdb.com")
    }

    private static func arkhamDBURL(from components: URLComponents) throws -> DeckImportURL {
        let parts = pathParts(components)
        guard ["deck", "decklist"].contains(parts.first ?? "") else {
            throw ParseError.invalid
        }
        let identifier: String
        if parts.count == 2 {
            identifier = parts[1]
        } else if parts.count == 3 || parts.count == 4 {
            guard parts[1] == "view" else { throw ParseError.invalid }
            identifier = parts[2]
        } else {
            throw ParseError.invalid
        }
        guard isNumericIdentifier(identifier) else { throw ParseError.invalid }
        return .fetchURL("https://arkhamdb.com/api/public/\(parts[0])/\(identifier)")
    }

    private static func arkhamBuildURL(
        from components: URLComponents,
        host: String
    ) throws -> DeckImportURL {
        let parts = pathParts(components)
        if host == "api.arkham.build" {
            guard parts.count == 4,
                  parts[0] == "v1",
                  parts[1] == "public",
                  parts[2] == "share",
                  isArkhamBuildIdentifier(parts[3])
            else { throw ParseError.invalid }
            let suffix = components.queryItems?.contains {
                $0.name == "type" && $0.value == "decklist"
            } == true ? "?type=decklist" : ""
            return .fetchURL("https://api.arkham.build/v1/public/share/\(parts[3])\(suffix)")
        }
        if parts.count == 2, parts[0] == "decklist", isArkhamBuildIdentifier(parts[1]) {
            return .fetchURL(
                "https://api.arkham.build/v1/public/share/\(parts[1])?type=decklist"
            )
        }
        let isDecklistView = parts.count == 3
            && parts[0] == "decklist"
            && parts[1] == "view"
            && isArkhamBuildIdentifier(parts[2])
        if isDecklistView {
            return .fetchURL(
                "https://api.arkham.build/v1/public/share/\(parts[2])?type=decklist"
            )
        }
        if parts.count == 2, ["share", "deck"].contains(parts[0]),
           isArkhamBuildIdentifier(parts[1])
        {
            return .fetchURL("https://api.arkham.build/v1/public/share/\(parts[1])")
        }
        let isShareView = parts.count == 3
            && parts[0] == "share"
            && parts[1] == "view"
            && isArkhamBuildIdentifier(parts[2])
        let isDeckView = parts.count == 3
            && parts[0] == "deck"
            && parts[1] == "view"
            && isArkhamBuildIdentifier(parts[2])
        if isShareView || isDeckView {
            return .fetchURL("https://api.arkham.build/v1/public/share/\(parts[2])")
        }
        throw ParseError.invalid
    }

    private static func pathParts(_ components: URLComponents) -> [String] {
        components.path.split(separator: "/").map(String.init)
    }

    private static func isNumericIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { character in
            character.isASCII && character.isNumber
        }
    }

    private static func isArkhamBuildIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber
                    || character == "-" || character == "_")
        }
    }
}

extension DeckImportURL.ParseError {
    var message: String {
        switch self {
        case .invalid:
            "Enter an https ArkhamDB deck/decklist URL or arkham.build deck/share URL."
        case .unsupportedArkhamBuildShare:
            "Enter an https ArkhamDB deck/decklist URL or arkham.build deck/share URL."
        }
    }
}
