import Foundation

enum BoardCampaignSummaryFormatting {
    static func logKeyIdentity(_ value: JSONValue) -> String {
        formatLogKey(value) ?? jsonDisplayValue(value)
    }

    static func logKeyTitle(_ value: JSONValue) -> String {
        titleizedWords(formatLogKey(value) ?? jsonDisplayValue(value))
    }

    static func jsonDisplayValue(_ value: JSONValue) -> String {
        switch value {
        case .null:
            "—"
        case let .bool(value):
            value ? "true" : "false"
        case let .number(number):
            number.description
        case let .string(value):
            titleizedWords(value)
        case let .array(values):
            values.map(jsonDisplayValue).joined(separator: ", ")
        case let .object(object):
            jsonObjectDisplayValue(object)
        }
    }

    static func titleizedWords(_ value: String) -> String {
        let leaf = value
            .replacingOccurrences(of: "'", with: "")
            .split(separator: ".")
            .last
            .map(String.init) ?? value
        let cleaned = leaf
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let pattern = #"[A-Z]?[a-z0-9]+|[A-Z]+(?![a-z])"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(cleaned.startIndex ..< cleaned.endIndex, in: cleaned)
        let words = regex?.matches(in: cleaned, range: range).compactMap { match -> String? in
            guard let range = Range(match.range, in: cleaned) else { return nil }
            return String(cleaned[range]).lowercased()
        } ?? cleaned.split(separator: " ").map { $0.lowercased() }
        guard let first = words.first else { return value }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }

    private static func jsonObjectDisplayValue(_ object: [String: JSONValue]) -> String {
        if let title = stringValue(object["title"]) {
            return title
        }
        if let name = stringValue(object["name"]) {
            return name
        }
        if let tag = stringValue(object["tag"]), let contents = object["contents"] {
            return "\(titleizedWords(tag)): \(jsonDisplayValue(contents))"
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
        return first.lowercased() + value.dropFirst()
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard case let .string(value)? = value else { return nil }
        return value
    }
}
