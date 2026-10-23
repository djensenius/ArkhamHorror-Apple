import Foundation

struct GameLogOutlineRow: Identifiable, Equatable {
    let id: String
    let depth: Int
    let entry: GameLogEntry
    let canExpand: Bool
    let isExpanded: Bool
    var toggleID: String?
    var autoExpanded: Bool = false
    var hiddenRowCount: Int = 0
    var isPinned: Bool = false

    var expansionID: String {
        toggleID ?? id
    }
}

/// The newest standalone spine and unfinished/latest group open automatically. Explicit
/// choices follow structured sequence identities, including through the server's sliding tail.
/// Parity: `frontend/src/arkham/components/GameLog.vue:75-137`.
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
            let hidden = open ? 0 : item.members.reduce(0) { $0 + size($1) }
            func bar(_ entry: GameLogEntry, id: String) -> GameLogOutlineRow {
                GameLogOutlineRow(
                    id: id, depth: 0, entry: entry,
                    canExpand: !item.members.isEmpty, isExpanded: open,
                    toggleID: item.id, autoExpanded: autoOpen,
                    hiddenRowCount: hidden,
                    isPinned: overrides[item.id].map { $0 != autoOpen } ?? false
                )
            }
            var rows: [GameLogOutlineRow] = []
            if let header = item.header {
                rows.append(bar(header, id: item.id))
            }
            if open {
                var occurrences: [String: Int] = [:]
                for member in item.members {
                    let memberID = GameLogPresentation.uniqueID(
                        "\(item.id).entry:\(member.seq)", occurrences: &occurrences
                    )
                    rows += entryRows(
                        member, id: memberID, depth: 1,
                        autoOpen: autoOpen, overrides: overrides
                    )
                }
            }
            // Both bars remain visible while detail folds; a missing header never moves
            // the result band ahead of the members. See LogGroupBlock.vue:76-137.
            if let summary = item.summary {
                rows.append(bar(summary, id: "\(item.id).summary"))
            }
            return rows
        }
    }

    private static func entryRows(
        _ entry: GameLogEntry, id: String, depth: Int,
        autoOpen: Bool, overrides: [String: Bool]
    ) -> [GameLogOutlineRow] {
        let annotated = !entry.children.isEmpty && entry.children.allSatisfy {
            $0.kind.rawValue == "Notice" && $0.children.isEmpty
        }
        let open = annotated || (overrides[id] ?? autoOpen)
        let row = GameLogOutlineRow(
            id: id, depth: depth, entry: entry,
            canExpand: !annotated && !entry.children.isEmpty, isExpanded: open,
            autoExpanded: autoOpen,
            hiddenRowCount: open ? 0 : entry.children.reduce(0) { $0 + size($1) },
            isPinned: !annotated && (overrides[id].map { $0 != autoOpen } ?? false)
        )
        guard open else { return [row] }
        // Nested seq values are always zero on the server; only their index path is meaningful.
        let children = entry.children.enumerated().flatMap { index, child in
            entryRows(
                child, id: "\(id).\(index)", depth: depth + 1,
                autoOpen: autoOpen, overrides: overrides
            )
        }
        // A standalone Test closes its detail with the result band, just like a group.
        return entry.kind.rawValue == "Test" && depth == 0 ? children + [row] : [row] + children
    }

    private static func size(_ entry: GameLogEntry) -> Int {
        1 + entry.children.reduce(0) { $0 + size($1) }
    }
}
