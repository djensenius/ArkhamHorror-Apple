import SwiftUI

/// The ordinary-location board — the board's single "board.locations" zone, laid out from
/// ``BoardLayout``'s deterministic grid positions. Connections are drawn as a
/// noninteractive, accessibility-hidden ``Canvas`` decoration behind the location tiles;
/// every tile itself remains an independent focusable/accessible view.
struct BoardLocationBoardView: View {
    let locations: [BoardLocationNode]
    let enemiesByLocationID: [LocationID: [BoardEnemyNode]]
    let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    let layout: BoardLayout
    let zoomScale: CGFloat
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void
    let onLinkedChoice: (Int) -> Void

    private let baseCellSize = CGSize(width: 150, height: 112)

    private func center(for position: BoardGridPosition) -> CGPoint {
        CGPoint(
            x: (CGFloat(position.column) + 0.5) * baseCellSize.width * zoomScale,
            y: (CGFloat(position.row) + 0.5) * baseCellSize.height * zoomScale
        )
    }

    var body: some View {
        let width = max(CGFloat(layout.columnCount), 1) * baseCellSize.width * zoomScale
        let height = max(CGFloat(layout.rowCount), 1) * baseCellSize.height * zoomScale
        VStack(alignment: .leading, spacing: 10) {
            BoardSectionHeading(title: "Locations")
            if locations.isEmpty {
                Text("No locations in this scenario")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ZStack(alignment: .topLeading) {
                    connectionsCanvas
                    ForEach(locations) { location in
                        locationTile(location)
                    }
                }
                .frame(width: width, height: height)
            }
        }
    }

    @ViewBuilder
    private func locationTile(_ location: BoardLocationNode) -> some View {
        if let position = layout.positions[location.id] {
            let id = BoardFocusID.location(location.id)
            let tileSize = CGSize(
                width: (baseCellSize.width * zoomScale) - 8,
                height: (baseCellSize.height * zoomScale) - 8
            )
            let enemies = enemiesByLocationID[location.id] ?? []
            let metrics = BoardLocationEnemyTileMetrics.current
            let enemyPanelHeight = max(
                tileSize.height - metrics.headerReservedHeight - metrics.verticalSpacing,
                0
            )
            VStack(spacing: metrics.verticalSpacing) {
                BoardEntityTile(
                    id: id,
                    accessibilityLabel: BoardAccessibility.summary(location: location),
                    isFocused: focusedID == id,
                    focusBinding: focusBinding,
                    onOutcome: onOutcome
                ) {
                    locationTileContent(location)
                }
                .fixedSize(horizontal: false, vertical: true)
                locationEnemyPanel(enemies, width: tileSize.width, height: enemyPanelHeight)
                    .frame(height: enemyPanelHeight, alignment: .top)
                    .clipped()
            }
            .frame(width: tileSize.width, height: tileSize.height, alignment: .top)
            .clipped()
            .position(center(for: position))
        }
    }

    private func locationTileContent(_ location: BoardLocationNode) -> some View {
        VStack(spacing: 4) {
            Text(location.displayLabel)
                .font(.subheadline.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(ArkhamTheme.bone)
            HStack(spacing: 4) {
                BoardStatBadge(systemImage: "sparkles", value: "\(location.clueCount)")
                if location.enemyCount > 0 {
                    BoardStatBadge(systemImage: "figure.walk", value: "\(location.enemyCount)")
                }
                if !location.investigatorIDs.isEmpty {
                    BoardStatBadge(
                        systemImage: "person.fill", value: "\(location.investigatorIDs.count)"
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func locationEnemyPanel(
        _ enemies: [BoardEnemyNode],
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let decision = BoardLocationEnemyTileLayout.decision(
            enemyCount: enemies.count,
            availableWidth: width,
            availableHeight: height,
            metrics: .current
        )
        switch decision {
        case .hidden:
            EmptyView()
        case .summaryButton:
            BoardEnemyOverflowMenu(
                label: "\(enemies.count) enemies",
                enemies: enemies,
                choiceLinks: choiceLinks,
                onLinkedChoice: onLinkedChoice
            )
        case let .chips(visibleCount, hasMore):
            HStack(spacing: BoardLocationEnemyTileMetrics.current.horizontalSpacing) {
                ForEach(Array(enemies.prefix(visibleCount))) { enemy in
                    BoardEnemyTileChipView(
                        enemy: enemy,
                        linkedChoices: choiceLinks[.enemy(enemy.id)] ?? [],
                        onLinkedChoice: onLinkedChoice
                    )
                }
                if hasMore {
                    BoardEnemyOverflowMenu(
                        label: "+\(enemies.count - visibleCount) more",
                        enemies: enemies,
                        choiceLinks: choiceLinks,
                        onLinkedChoice: onLinkedChoice
                    )
                }
            }
        }
    }

    private var connectionsCanvas: some View {
        Canvas { context, _ in
            for edge in layout.connections {
                guard let firstPosition = layout.positions[edge.first],
                      let secondPosition = layout.positions[edge.second]
                else { continue }
                var path = Path()
                path.move(to: center(for: firstPosition))
                path.addLine(to: center(for: secondPosition))
                context.stroke(path, with: .color(ArkhamTheme.accent.opacity(0.35)), lineWidth: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The enemy-spawned pseudo-location row — the board's single "board.enemyLocations" zone.
struct BoardEnemyLocationsRowView: View {
    let enemyLocations: [BoardEnemyLocationNode]
    let enemiesByLocationID: [LocationID: [BoardEnemyNode]]
    let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BoardSectionHeading(title: "Enemy locations")
            if enemyLocations.isEmpty {
                Text("No enemy-spawned locations")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(enemyLocations) { location in
                            tile(location)
                        }
                    }
                }
            }
        }
    }

    private func tile(_ location: BoardEnemyLocationNode) -> some View {
        let id = BoardFocusID.enemyLocation(location.id)
        return VStack(spacing: 6) {
            BoardEntityTile(
                id: id,
                accessibilityLabel: BoardAccessibility.summary(enemyLocation: location),
                isFocused: focusedID == id,
                focusBinding: focusBinding,
                onOutcome: onOutcome
            ) {
                VStack(spacing: 4) {
                    Text(location.displayLabel)
                        .font(.subheadline.bold())
                        .foregroundStyle(ArkhamTheme.bone)
                    HStack(spacing: 4) {
                        BoardStatBadge(systemImage: "figure.walk", value: "\(location.enemyCount)")
                        if !location.investigatorIDs.isEmpty {
                            BoardStatBadge(
                                systemImage: "person.fill",
                                value: "\(location.investigatorIDs.count)"
                            )
                        }
                    }
                }
            }
            if let enemies = enemiesByLocationID[location.id], !enemies.isEmpty {
                BoardEnemyCompactPanelView(
                    title: "Enemies",
                    enemies: enemies,
                    visibleCount: 3,
                    choiceLinks: choiceLinks,
                    onLinkedChoice: onLinkedChoice
                )
            }
        }
        .accessibilityElement(children: .contain)
    }
}
