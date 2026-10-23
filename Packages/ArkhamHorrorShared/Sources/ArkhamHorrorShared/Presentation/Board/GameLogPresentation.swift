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
    static func legacyLocations(
        in locations: [BoardLocationNode]
    ) -> [String: LegacyGameLogParser.Location] {
        Dictionary(locations.map { location in
            (location.id.rawValue.uuidString.lowercased(), LegacyGameLogParser.Location(
                cardCode: location.cardCode.rawValue, revealed: location.revealed
            ))
        }, uniquingKeysWith: { first, _ in first })
    }

    static func items(
        rows: [GameLogRow], playerID: PlayerID?,
        locations: [String: LegacyGameLogParser.Location] = [:]
    ) -> [GameLogItem] {
        var items: [GameLogItem] = []
        var groups: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            let identity = identity(for: row, index: index)
            let entry = normalizedEntry(row, locations: locations)
            guard let visible = visibleEntry(entry, playerID: playerID) else { continue }
            guard let group = visible.group, !group.id.isEmpty else {
                items.append(GameLogItem(
                    id: identity, header: nil, members: [visible], summary: nil
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
        var occurrences: [String: Int] = [:]
        return items.flatMap { item in
            item.isGroup ? [item] : item.members.map { entry in
                GameLogItem(
                    id: item.id.hasPrefix("group:") ? "entry:\(entry.seq)" : item.id,
                    header: nil, members: [entry], summary: nil
                )
            }
        }.map { item in
            GameLogItem(
                id: uniqueID(item.id, occurrences: &occurrences), header: item.header,
                members: item.members, summary: item.summary
            )
        }
    }

    /// Top-level seq values should be unique; retain every row if a server violates that rule.
    static func uniqueID(_ base: String, occurrences: inout [String: Int]) -> String {
        occurrences[base, default: 0] += 1
        let count = occurrences[base, default: 0]
        return count == 1 ? base : "\(base)#\(count)"
    }

    private static func normalizedEntry(
        _ row: GameLogRow, locations: [String: LegacyGameLogParser.Location]
    ) -> GameLogEntry {
        switch row {
        case let .legacy(text, step):
            GameLogEntry(
                seq: 0, step: step, kind: OpenStringEnum("Mechanic"),
                body: LegacyGameLogParser.parse(text, locations: locations),
                source: nil, children: [], audience: .everyone,
                context: GameLogContext(round: nil, phase: nil, turn: nil), tone: nil, group: nil
            )
        case let .structured(entry): entry
        }
    }

    private static func identity(for row: GameLogRow, index: Int) -> String {
        switch row {
        case .legacy: "legacy:\(index)"
        case let .structured(entry): "entry:\(entry.seq)"
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

    /// The final summary part is the arithmetic stripe, not another sentence fragment.
    /// Parity: `frontend/src/arkham/components/LogGroupBlock.vue:52-59,124-126`.
    func renderBody(of entry: GameLogEntry, depth: Int = 0) -> [StoryNode] {
        guard entry.group?.role.rawValue == "GroupSummary"
            || (entry.kind.rawValue == "Test" && depth == 0
                && entry.group?.role.rawValue != "GroupHeader"),
            entry.body.count > 1,
            let statistics = entry.body.last else { return render(entry.body) }
        return render(Array(entry.body.dropLast())) + [.lineBreak] + render(statistics)
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
        let json = variables.reduce(into: [String: JSONValue]()) { result, pair in
            let (name, part) = pair
            if case let .number(number) = part {
                result[name] = .number(number)
            } else if name != "count", name != "n" {
                result[name] = .string((rich[name] ?? []).map(\.plainText).joined())
            }
            // A nonnumeric selector leaves plural selection unset on the web. Its rich
            // value remains available for interpolation, with the implicit singular rule.
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
        let faceName = Self.suffixedTokenFaces[token] ?? token
        let normalized = faceName.prefix(1).lowercased() + faceName.dropFirst()
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
        guard let regex = Self.runePattern else { return [.text(text)] }
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

    private static let runePattern = try? NSRegularExpression(
        pattern: #"\{rune([A-Z])\}|\[tdc_rune_([A-Za-z])\]"#
    )

    private static let suffixedTokenFaces = [
        "BlessToken": "Bless", "CurseToken": "Curse", "FrostToken": "Frost", "BloodToken": "Blood",
    ]

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

    static var expanded: String {
        text("gameLog.expanded")
    }

    static var collapsed: String {
        text("gameLog.collapsed")
    }

    static func level(_ level: Int) -> String {
        String(format: text("gameLog.level"), level)
    }

    static func hiddenRows(_ count: Int) -> String {
        String(format: text("gameLog.hiddenRows"), count)
    }

    static var pinned: String {
        text("gameLog.pinned")
    }

    static func accessibilityValue(for row: GameLogOutlineRow) -> String {
        var values = [row.isExpanded ? expanded : collapsed, level(row.depth + 1)]
        if row.hiddenRowCount > 0 {
            values.append(hiddenRows(row.hiddenRowCount))
        }
        if row.isPinned {
            values.append(pinned)
        }
        return values.joined(separator: ", ")
    }

    static func unavailable(_ key: String) -> String {
        String(format: text("gameLog.unavailable"), key)
    }

    private static func text(_ key: String) -> String {
        CampaignPromptLocalization.localized(key, key)
    }
}
