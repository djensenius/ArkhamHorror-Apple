import Foundation

/// Closed legacy brace DSL, ported from `frontend/src/arkham/legacyLogParse.ts:26-142`.
/// Unknown brace fragments remain literal; bare/whole $keys remain typed i18n requests.
enum LegacyGameLogParser {
    struct Location: Sendable {
        let cardCode: String
        let revealed: Bool
    }

    static func parse(_ body: String, locations: [String: Location] = [:]) -> [GameLogPart] {
        let normalized = body.replacingOccurrences(
            of: #"\{token:"CustomToken "([^"]+)""\}"#,
            with: #"{token:"$1"}"#, options: .regularExpression
        )
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let invocation = isWholeI18nToken(trimmed)
            ? StoryNarrativeLocalization.parseProductionChoiceLabel(trimmed) : nil
        if let invocation, case let .object(variables) = invocation.variables {
            return [.i18n(key: invocation.key, variables: variables.compactMapValues { value in
                switch value {
                case let .number(number): .number(number)
                case let .string(text): .text(text)
                default: nil
                }
            })]
        }
        return split(normalized, pattern: #"\{[^}]+\}"#).flatMap { fragment in
            if fragment.hasPrefix("{"), fragment.hasSuffix("}") {
                return [parseRef(fragment, locations: locations) ?? .text(fragment)]
            }
            return split(fragment, pattern: #"\$[A-Za-z0-9_.]+"#).map { piece in
                piece.hasPrefix("$")
                    ? .i18n(key: String(piece.dropFirst()), variables: [:]) : .text(piece)
            }
        }
    }

    private static func isWholeI18nToken(_ text: String) -> Bool {
        guard text.hasPrefix("$") else { return false }
        guard let space = text.firstIndex(of: " ") else { return true }
        let rest = String(text[text.index(after: space)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = #"(?:"(?:[^"\\]|\\.)*"|\S+)"#
        return matches("^[A-Za-z0-9_]+=[is]:\(value)(\\s+[A-Za-z0-9_]+=[is]:\(value))*$", rest) !=
            nil
    }

    private static func parseRef(
        _ fragment: String, locations: [String: Location]
    ) -> GameLogPart? {
        if let values = matches(#"^\{card:"((?:[^"]|\\.)+)":"?([^":]+)"?:"([^"]+)"\}$"#, fragment) {
            return ref("RefCard", values[0], cardCode: values[1], cardID: values[2])
        }
        if let values = matches(#"^\{investigator:"((?:[^"]|\\.)+)":"([^"]+)"\}$"#, fragment) {
            return ref("RefInvestigator", values[0], cardCode: values[1], entityID: values[1])
        }
        if let values = matches(#"^\{enemy:"((?:[^"]|\\.)+)":(.+):"([^"]+)"\}$"#, fragment) {
            return ref("RefEnemy", values[0], cardCode: values[2])
        }
        if let values = matches(#"^\{location:"((?:[^"]|\\.)+)":(.+):"([^"]+)"\}$"#, fragment) {
            let id = values[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let live = locations[id]
            return ref(
                "RefLocation", values[0], cardCode: live?.cardCode ?? values[2],
                entityID: values[1], faceDown: live.map { !$0.revealed } ?? false
            )
        }
        if let values = matches(#"^\{location:"((?:[^"]|\\.)+)":(.+)\}$"#, fragment) {
            return ref("RefLocation", values[0], entityID: values[1])
        }
        if let values = matches(#"^\{token:"([^"]+)"\}$"#, fragment) {
            return .token(values[0])
        }
        return nil
    }

    private static func ref(
        _ kind: String, _ name: String, cardCode: String? = nil,
        cardID: String? = nil, entityID: String? = nil, faceDown: Bool = false
    ) -> GameLogPart {
        .ref(GameLogRef(
            kind: OpenStringEnum(kind),
            name: name.replacingOccurrences(of: #"\""#, with: "\""),
            cardCode: cardCode, cardID: cardID, entityID: entityID, faceDown: faceDown
        ))
    }

    private static func matches(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1 ..< match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private static func split(_ text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        var pieces: [String] = []
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            if cursor < range.lowerBound {
                pieces.append(String(text[cursor ..< range.lowerBound]))
            }
            pieces.append(String(text[range]))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            pieces.append(String(text[cursor...]))
        }
        return pieces
    }
}
