import Foundation

struct BoardCampaignSummaryLocalization: Sendable {
    let string: @Sendable (_ key: String, _ fallback: String) -> String

    func localized(_ key: String, _ fallback: String) -> String {
        string(key, fallback)
    }

    static let system = BoardCampaignSummaryLocalization { key, fallback in
        NSLocalizedString(key, bundle: .module, value: fallback, comment: "")
    }
}

struct BoardCampaignSummaryDisplayContext: Sendable {
    let localeCatalogResolver: LocaleCatalogResolver?
    let cardCatalog: CardCatalogSnapshot?
    let localization: BoardCampaignSummaryLocalization

    init(
        localeCatalogResolver: LocaleCatalogResolver? = nil,
        cardCatalog: CardCatalogSnapshot? = nil,
        localization: BoardCampaignSummaryLocalization = .system
    ) {
        self.localeCatalogResolver = localeCatalogResolver
        self.cardCatalog = cardCatalog
        self.localization = localization
    }

    static let system = BoardCampaignSummaryDisplayContext()
}

enum BoardCampaignSummaryFormatting {
    static func logKeyIdentity(_ value: JSONValue) -> String {
        formatLogKey(value) ?? jsonDisplayValue(value)
    }

    static func logKeyTitle(
        _ value: JSONValue,
        context: BoardCampaignSummaryDisplayContext = .system
    ) -> String {
        let path = formatLogKey(value) ?? jsonDisplayValue(value, context: context)
        return localizedLogKeyTitle(path, context: context)
    }

    static func localizedLogKeyTitle(
        _ path: String,
        context: BoardCampaignSummaryDisplayContext
    ) -> String {
        guard let resolver = context.localeCatalogResolver else {
            return titleizedWords(path)
        }
        switch resolver.render(key: path, variables: .object([:])) {
        case let .success(nodes):
            let text = nodes.map(\.plainText).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? titleizedWords(path) : text
        case .failure(.missingKey):
            return titleizedWords(path)
        case .failure:
            return titleizedWords(path)
        }
    }

    static func jsonDisplayValue(
        _ value: JSONValue,
        context: BoardCampaignSummaryDisplayContext = .system
    ) -> String {
        switch value {
        case .null:
            "—"
        case let .bool(value):
            context.localization.localized(
                value ? "campaign.summary.boolean.true" : "campaign.summary.boolean.false",
                value ? "True" : "False"
            )
        case let .number(number):
            number.description
        case let .string(value):
            titleizedWords(value)
        case let .array(values):
            values.map { jsonDisplayValue($0, context: context) }.joined(separator: ", ")
        case let .object(object):
            jsonObjectDisplayValue(object, context: context)
        }
    }

    static func titleizedWords(_ value: String) -> String {
        let leaf = value
            .split(separator: ".")
            .last
            .map(String.init) ?? value
        let cleaned = leaf
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let pattern = #"[A-Z]?[a-z']+|[A-Z]+(?![a-z])|\d+"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(cleaned.startIndex ..< cleaned.endIndex, in: cleaned)
        let words = regex?.matches(in: cleaned, range: range).compactMap { match -> String? in
            guard let range = Range(match.range, in: cleaned) else { return nil }
            return String(cleaned[range]).lowercased()
        } ?? cleaned.split(separator: " ").map { $0.lowercased() }
        guard let first = words.first else { return value }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
    }

    static func splitCamelCase(_ value: String) -> String {
        let pattern = #"([a-z])([A-Z])"#
        return value.replacingOccurrences(of: pattern, with: "$1 $2", options: .regularExpression)
    }

    static func cardDisplayName(
        for rawCode: String,
        context: BoardCampaignSummaryDisplayContext
    ) -> String? {
        let candidates = rawCode.hasPrefix("c") ? [rawCode] : ["c\(rawCode)", rawCode]
        for candidate in candidates {
            if let code = try? CardCode(candidate),
               let title = context.cardCatalog?.displayName(for: code) {
                return title
            }
        }
        return nil
    }

    private static func jsonObjectDisplayValue(
        _ object: [String: JSONValue],
        context: BoardCampaignSummaryDisplayContext
    ) -> String {
        if let title = stringValue(object["title"]) {
            return title
        }
        if let name = stringValue(object["name"]) {
            return name
        }
        if let tag = stringValue(object["tag"]), let contents = object["contents"] {
            return "\(titleizedWords(tag)): \(jsonDisplayValue(contents, context: context))"
        }
        if let tag = stringValue(object["tag"]) {
            return titleizedWords(tag)
        }
        return titleizedWords(object.keys.sorted().joined(separator: ", "))
    }

    private static func formatLogKey(_ value: JSONValue) -> String? {
        guard case let .object(object) = value,
              let tag = stringValue(object["tag"])
        else { return nil }
        let prefix = lowerFirst(tag.replacingOccurrences(of: "Key", with: ""))
        guard let contents = object["contents"] else {
            return "base.key.\(lowerFirst(tag))"
        }
        if case let .object(nested) = contents {
            if let nestedTag = stringValue(nested["tag"]) {
                return nestedLogKey(prefix: prefix, nestedTag: nestedTag, nested: nested)
            }
        }
        if let text = stringValue(contents) {
            if tag == "HomebrewCampaignLogKey" {
                let parts = text.split(separator: ".", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    return "\(lowerFirst(parts[0])).key.\(lowerFirst(parts[1]))"
                }
            }
            return "\(prefix).key.\(lowerFirst(text))"
        }
        return "\(prefix).key.unknown"
    }

    private static func nestedLogKey(
        prefix: String,
        nestedTag: String,
        nested: [String: JSONValue]
    ) -> String {
        let section = lowerFirst(nestedTag)
        if let nestedContents = stringValue(nested["contents"]) {
            return "\(prefix).key['[\(section)]'].\(lowerFirst(nestedContents))"
        }
        return "\(prefix).key.\(section)"
    }

    private static func lowerFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return (first.lowercased() + value.dropFirst()).replacingOccurrences(of: "'", with: "")
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard case let .string(value)? = value else { return nil }
        return value
    }
}
