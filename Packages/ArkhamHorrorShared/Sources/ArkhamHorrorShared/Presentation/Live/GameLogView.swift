import SwiftUI

/// Read-only history: no chat, undo, or fabricated pagination targets.
/// A native sheet on iOS, macOS, and visionOS; tvOS rows explicitly participate in focus.
struct GameLogView: View {
    let projection: BoardProjection
    let playerID: PlayerID?
    let resolver: LocaleCatalogResolver?
    let cardCatalog: CardCatalogSnapshot?

    @State private var expansionOverrides: [String: Bool] = [:]
    @State private var scrollState = GameLogScrollState()
    @State private var isReaderScrolling = false
    @Environment(\.dismiss) private var dismiss

    private var items: [GameLogItem] {
        let locations = GameLogPresentation.legacyLocations(in: projection.locations)
        return GameLogPresentation.items(
            rows: projection.gameLog, playerID: playerID, locations: locations
        )
    }

    var body: some View {
        let presentedItems = items
        let rows = GameLogOutline.rows(items: presentedItems, overrides: expansionOverrides)
        NavigationStack {
            ScrollViewReader { scroll in
                List {
                    if presentedItems.isEmpty {
                        Text(GameLogLocalization.empty)
                            .accessibilityIdentifier("gameLog.empty")
                    }
                    ForEach(rows) { row in
                        logRow(row)
                            .id(row.id)
                            .padding(.leading, CGFloat(min(row.depth, 6)) * 16)
                            .accessibilityIdentifier("gameLog.row.\(row.id)")
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY
                } action: { _, distanceFromBottom in
                    if isReaderScrolling {
                        scrollState.readerScrolled(distanceFromBottom: distanceFromBottom)
                    }
                }
                .onScrollPhaseChange { oldPhase, phase, context in
                    isReaderScrolling = phase != .idle && phase != .animating
                    // Layout changes caused by arrivals must not unpin the live tail.
                    if isReaderScrolling || (phase == .idle && oldPhase != .animating) {
                        scrollState.readerScrolled(distanceFromBottom:
                            context.geometry.contentSize.height - context.geometry.visibleRect.maxY)
                    }
                }
                .onChange(of: rows.map(\.id), initial: true) { _, rowIDs in
                    if let target = scrollState.renderedRowsChanged(rowIDs) {
                        scroll.scrollTo(target, anchor: .bottom)
                    }
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
            .renderBody(of: row.entry, depth: row.depth)
        if row.canExpand {
            Button {
                let expanded = !row.isExpanded
                expansionOverrides[row.expansionID] = expanded == row.autoExpanded ? nil : expanded
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .accessibilityHidden(true)
                    sentence(nodes, entry: row.entry)
                    if row.hiddenRowCount > 0 {
                        Text("+\(row.hiddenRowCount)").font(.caption)
                            .accessibilityHidden(true)
                    }
                    if row.isPinned {
                        Image(systemName: "pin.fill").font(.caption)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityLabel(nodes.map(\.plainText).joined())
            .accessibilityValue(GameLogLocalization.accessibilityValue(for: row))
        } else {
            sentence(nodes, entry: row.entry)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(nodes.map(\.plainText).joined())
                .accessibilityValue(GameLogLocalization.level(row.depth + 1))
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
