import SwiftUI

/// Read-only history: no chat, undo, or fabricated pagination targets.
/// A native sheet on iOS, macOS, and visionOS; tvOS rows explicitly participate in focus.
struct GameLogView: View {
    let projection: BoardProjection
    let playerID: PlayerID?
    let resolver: LocaleCatalogResolver?
    let cardCatalog: CardCatalogSnapshot?

    @State private var expansionOverrides: [String: Bool] = [:]
    @Environment(\.dismiss) private var dismiss

    private var items: [GameLogItem] {
        let locations = Dictionary(uniqueKeysWithValues: projection.locations.map { location in
            (location.id.description, LegacyGameLogParser.Location(
                cardCode: location.cardCode.rawValue, revealed: location.revealed
            ))
        })
        return GameLogPresentation.items(
            rows: projection.gameLog, playerID: playerID, locations: locations
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text(GameLogLocalization.empty)
                        .accessibilityIdentifier("gameLog.empty")
                }
                ForEach(GameLogOutline.rows(items: items, overrides: expansionOverrides)) { row in
                    logRow(row)
                        .padding(.leading, CGFloat(min(row.depth, 6)) * 16)
                        .accessibilityIdentifier("gameLog.row.\(row.id)")
                }
            }
            .navigationTitle(GameLogLocalization.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(GameLogLocalization.close) { dismiss() }
                        .accessibilityIdentifier("gameLog.close")
                }
            }
        }
        .frame(minWidth: 300, minHeight: 300)
        .accessibilityIdentifier("gameLog.surface")
    }

    @ViewBuilder
    private func logRow(_ row: GameLogOutlineRow) -> some View {
        let nodes = GameLogPartRenderer(resolver: resolver, cardCatalog: cardCatalog)
            .render(row.entry.body)
        if row.canExpand {
            Button {
                expansionOverrides[row.id] = !row.isExpanded
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .accessibilityHidden(true)
                    sentence(nodes, entry: row.entry)
                }
            }
            .accessibilityLabel(nodes.map(\.plainText).joined())
            .accessibilityValue(row.isExpanded ? GameLogLocalization.expanded : GameLogLocalization
                .collapsed)
        } else {
            sentence(nodes, entry: row.entry)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(nodes.map(\.plainText).joined())
            #if os(tvOS)
                .focusable()
            #endif
        }
    }

    private func sentence(_ nodes: [StoryNode], entry: GameLogEntry) -> some View {
        StoryNodeSequenceView(nodes: nodes)
            .fontWeight(entry.kind.rawValue == "Structure" ? .bold : .regular)
            .italic(entry.kind.rawValue == "Chat")
            .padding(.vertical, 4)
            .overlay(alignment: .leading) {
                if let tone = entry.tone?.rawValue, tone == "Good" || tone == "Bad" {
                    Rectangle()
                        .fill(tone == "Good" ? Color.green : Color.red)
                        .frame(width: 3)
                        .offset(x: -8)
                        .accessibilityHidden(true)
                }
            }
    }
}
