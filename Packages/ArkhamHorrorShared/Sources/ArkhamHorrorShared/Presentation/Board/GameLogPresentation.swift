import Foundation

struct GameLogItem: Identifiable, Equatable {
    let id: String
    var header: GameLogEntry?
    var members: [GameLogEntry]
    var summary: GameLogEntry?

    var isGroup: Bool {
        header != nil || summary != nil
    }
}

/// Normalizes legacy rows, recursively filters audiences, and groups by identity (not adjacency).
/// Parity: `frontend/src/arkham/types/GameLog.ts:301-350`, `GameLog.vue:56-61`.
enum GameLogPresentation {
    static func items(
        rows: [GameLogRow], playerID: PlayerID?,
        locations: [String: LegacyGameLogParser.Location] = [:]
    ) -> [GameLogItem] {
        var items: [GameLogItem] = []
        var groups: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            let entry: GameLogEntry = switch row {
            case let .legacy(text, step):
                GameLogEntry(
                    seq: 0, step: step, kind: OpenStringEnum("Mechanic"),
                    body: LegacyGameLogParser.parse(text, locations: locations),
                    source: nil, children: [], audience: .everyone,
                    context: GameLogContext(round: nil, phase: nil, turn: nil), tone: nil,
                    group: nil
                )
            case let .structured(structured): structured
            }
            guard let visible = visibleEntry(entry, playerID: playerID) else { continue }
            guard let group = visible.group, !group.id.isEmpty else {
                items.append(GameLogItem(
                    id: "entry:\(index)", header: nil, members: [visible], summary: nil
                ))
                continue
            }
            let position: Int
            if let existing = groups[group.id] {
                position = existing
            } else {
                position = items.count
                groups[group.id] = position
                items.append(GameLogItem(
                    id: "group:\(group.id)", header: nil, members: [], summary: nil
                ))
            }
            switch group.role.rawValue {
            case "GroupHeader": items[position].header = visible
            case "GroupSummary": items[position].summary = visible
            default: items[position].members.append(visible)
            }
        }
        // Undo can remove a group's bars. Its surviving members must remain visible.
        return items.flatMap { item in
            item.isGroup ? [item] : item.members.enumerated().map { index, entry in
                GameLogItem(
                    id: "\(item.id):\(index)", header: nil, members: [entry], summary: nil
                )
            }
        }
    }

    private static func visibleEntry(_ entry: GameLogEntry, playerID: PlayerID?) -> GameLogEntry? {
        guard entry.isVisible(to: playerID) else { return nil }
        return GameLogEntry(
            seq: entry.seq, step: entry.step, kind: entry.kind, body: entry.body,
            source: entry.source,
            children: entry.children.compactMap { visibleEntry($0, playerID: playerID) },
            audience: entry.audience, context: entry.context, tone: entry.tone, group: entry.group
        )
    }
}

/// Parts use the same catalog and glyph-aware StoryNode tree as live story text.
/// Parity: `frontend/src/arkham/components/LogPart.vue:33-55,80-167`.
struct GameLogPartRenderer {
    let resolver: LocaleCatalogResolver?
    var cardCatalog: CardCatalogSnapshot?

    func render(_ parts: [GameLogPart]) -> [StoryNode] {
        parts.flatMap { render($0) }
    }

    func render(_ part: GameLogPart) -> [StoryNode] {
        switch part {
        case let .text(text): runeNodes(text)
        case let .i18n(key, variables): localized(key, variables: variables)
        case let .ref(reference): referenceNodes(reference)
        case let .number(number): [.text(number.description)]
        case let .delta(number):
            [.text(number.sign == .minus ? "−\(number.description.dropFirst())" : "+\(number)")]
        case let .token(token): tokenNodes(token)
        case let .icon(name): iconNodes(name)
        case let .campaignKey(key):
            [.text(BoardCampaignSummaryFormatting.logKeyTitle(key, context: .init(
                localeCatalogResolver: resolver, cardCatalog: cardCatalog
            )))]
        case let .list(parts):
            parts.enumerated().flatMap { index, part in
                let separator: [StoryNode] = index == 0 ? [] : localized(
                    index == parts.count - 1 ? "log.listLast" : "log.listSeparator", variables: [:]
                )
                return separator + render(part)
            }
        }
    }

    private func localized(_ key: String, variables: [String: GameLogPart]) -> [StoryNode] {
        let rich = variables.mapValues { render($0) }
        let json = variables.mapValues { part -> JSONValue in
            switch part {
            case let .number(number): .number(number)
            default: .string(render(part).map(\.plainText).joined())
            }
        }
        let resolution = resolver?.render(key: key, variables: .object(json), richVariables: rich)
        if case let .success(nodes) = resolution {
            return nodes
        }
        // Never present an unresolved key as a translated sentence. Retain the supplied
        // values after an explicit app-localized diagnostic instead of inventing server prose.
        let values = variables.keys.sorted().flatMap { name in
            [StoryNode.text(" · \(name): ")] + (rich[name] ?? [])
        }
        return [.text(GameLogLocalization.unavailable(key))] + values
    }

    private func referenceNodes(_ reference: GameLogRef) -> [StoryNode] {
        var name = reference.name
        let code = reference.cardCode.map { raw in
            raw.hasPrefix("c") ? String(raw.dropFirst()) : raw
        }
        if let code {
            let bare = code.replacingOccurrences(
                of: "[a-h]$",
                with: "",
                options: .regularExpression
            )
            let exactName = (try? CardCode("c" + code))
                .flatMap { cardCatalog?.displayName(for: $0) }
            let bareName = (try? CardCode("c" + bare)).flatMap { cardCatalog?.displayName(for: $0) }
            name = exactName ?? bareName ?? name
        }
        let nodes = runeNodes(name)
        return code.map { [.cardReference(code: $0, children: nodes)] } ?? nodes
    }

    private func tokenNodes(_ token: String) -> [StoryNode] {
        if let value = Self.numericTokens[token] {
            return [.text(value)]
        }
        let normalized = token.prefix(1).lowercased() + token.dropFirst()
        if let face = ChaosTokenArtFace.iconVariableValue(normalized) {
            return [.semanticIcon(.chaosToken(face))]
        }
        return [.icon(token)]
    }

    private func iconNodes(_ name: String) -> [StoryNode] {
        let normalized = [
            "elder-thing": "elderThing",
            "elder-sign": "elderSign",
            "auto-fail": "autoFail",
        ][name] ?? name
        if let icon = StoryIcon.iconVariableValue(normalized) {
            return [.semanticIcon(icon)]
        }
        return [.icon(normalized)]
    }

    private func runeNodes(_ text: String) -> [StoryNode] {
        let pattern = #"\{rune([A-Z])\}|\[tdc_rune_([A-Za-z])\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [.text(text)] }
        var result: [StoryNode] = []
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            if cursor < range.lowerBound {
                result.append(.text(String(text[cursor ..< range.lowerBound])))
            }
            let letterRange = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            if let letter = Range(letterRange, in: text) {
                result.append(.icon("rune-\(text[letter].uppercased())"))
            }
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result.append(.text(String(text[cursor...])))
        }
        return result
    }

    private static let numericTokens = [
        "PlusOne": "+1", "Zero": "0", "MinusOne": "−1", "MinusTwo": "−2",
        "MinusThree": "−3", "MinusFour": "−4", "MinusFive": "−5", "MinusSix": "−6",
        "MinusSeven": "−7", "MinusEight": "−8",
    ]
}

enum GameLogLocalization {
    static var title: String {
        text("gameLog.title")
    }

    static var empty: String {
        text("gameLog.empty")
    }

    static var close: String {
        text("gameLog.close")
    }

    static func unavailable(_ key: String) -> String {
        String(format: text("gameLog.unavailable"), key)
    }

    private static func text(_ key: String) -> String {
        CampaignPromptLocalization.localized(key, key)
    }
}
