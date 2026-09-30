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
            return try arkhamBuildURL(from: components)
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

    private static func arkhamBuildURL(from components: URLComponents) throws -> DeckImportURL {
        let parts = pathParts(components)
        if parts.count == 2, parts[0] == "decklist", isArkhamBuildIdentifier(parts[1]) {
            return .fetchURL("https://arkham.build/decklist/\(parts[1])")
        }
        let isDecklistView = parts.count == 3
            && parts[0] == "decklist"
            && parts[1] == "view"
            && isArkhamBuildIdentifier(parts[2])
        if isDecklistView {
            return .fetchURL("https://arkham.build/decklist/\(parts[2])")
        }
        if parts.count == 2, ["share", "deck"].contains(parts[0]) {
            throw ParseError.unsupportedArkhamBuildShare
        }
        let isShareView = parts.count == 3 && parts[0] == "share" && parts[1] == "view"
        let isDeckView = parts.count == 3 && parts[0] == "deck" && parts[1] == "view"
        if isShareView || isDeckView {
            throw ParseError.unsupportedArkhamBuildShare
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
            "Enter an https ArkhamDB deck/decklist URL or arkham.build decklist URL."
        case .unsupportedArkhamBuildShare:
            "arkham.build share links are not supported yet. Paste an arkham.build decklist link."
        }
    }
}
