import Foundation

struct GameLogOutlineRow: Identifiable, Equatable {
    let id: String
    let depth: Int
    let entry: GameLogEntry
    let canExpand: Bool
    let isExpanded: Bool
}

/// The newest standalone spine and unfinished/latest group open automatically. Explicit
/// choices survive arrivals. Parity: `frontend/src/arkham/components/GameLog.vue:75-137`.
enum GameLogOutline {
    static func rows(
        items: [GameLogItem], overrides: [String: Bool] = [:]
    ) -> [GameLogOutlineRow] {
        let tail = items.lastIndex { !$0.isGroup && $0.members.first?.children.isEmpty == false }
        return items.enumerated().flatMap { index, item -> [GameLogOutlineRow] in
            if !item.isGroup {
                return item.members.flatMap {
                    entryRows(
                        $0, id: item.id, depth: 0, autoOpen: index == tail, overrides: overrides
                    )
                }
            }
            let autoOpen = !items.dropFirst(index + 1).contains {
                $0.isGroup || $0.members.contains { $0.kind.rawValue != "Chat" }
            }
            let open = overrides[item.id] ?? autoOpen
            let label = open ? (item.header ?? item.summary) : (item.summary ?? item.header)
            guard let label else { return [] }
            var rows = [GameLogOutlineRow(
                id: item.id, depth: 0, entry: label,
                canExpand: !item.members.isEmpty, isExpanded: open
            )]
            if open {
                for (memberIndex, member) in item.members.enumerated() {
                    rows += entryRows(
                        member, id: "\(item.id).\(memberIndex)", depth: 1,
                        autoOpen: autoOpen, overrides: overrides
                    )
                }
                if item.header != nil, let summary = item.summary {
                    rows += entryRows(
                        summary, id: "\(item.id).summary", depth: 0,
                        autoOpen: autoOpen, overrides: overrides
                    )
                }
            }
            return rows
        }
    }

    private static func entryRows(
        _ entry: GameLogEntry, id: String, depth: Int,
        autoOpen: Bool, overrides: [String: Bool]
    ) -> [GameLogOutlineRow] {
        let open = overrides[id] ?? autoOpen
        let row = GameLogOutlineRow(
            id: id, depth: depth, entry: entry,
            canExpand: !entry.children.isEmpty, isExpanded: open
        )
        guard open else { return [row] }
        return [row] + entry.children.enumerated().flatMap { index, child in
            entryRows(
                child, id: "\(id).\(index)", depth: depth + 1,
                autoOpen: autoOpen, overrides: overrides
            )
        }
    }
}
