import SwiftUI

private struct BoardLocationHeaderHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [LocationID: CGFloat] = [:]

    static func reduce(value: inout [LocationID: CGFloat], nextValue: () -> [LocationID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// swiftlint:disable type_body_length
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
    @State private var measuredHeaderHeights: [LocationID: CGFloat] = [:]

    private var effectiveCellSize: CGSize {
        BoardLocationTileGeometryPlan.plan(
            zoomScale: zoomScale,
            hasLinkedEnemyActions: boardHasLinkedEnemyActions,
            metrics: .current
        ).cellSize
    }

    private var boardHasLinkedEnemyActions: Bool {
        locations.contains { location in
            let enemies = enemiesByLocationID[location.id] ?? []
            let linkedEnemyChoices = BoardFocusGraphBuilder.linkedEnemyChoices(
                for: enemies,
                choiceLinks: choiceLinks
            )
            return hasFocusableLinkedEnemyActions(linkedEnemyChoices)
        }
    }

    private func center(for position: BoardGridPosition) -> CGPoint {
        CGPoint(
            x: (CGFloat(position.column) + 0.5) * effectiveCellSize.width,
            y: (CGFloat(position.row) + 0.5) * effectiveCellSize.height
        )
    }

    var body: some View {
        let width = max(CGFloat(layout.columnCount), 1) * effectiveCellSize.width
        let height = max(CGFloat(layout.rowCount), 1) * effectiveCellSize.height
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
                .onPreferenceChange(BoardLocationHeaderHeightPreferenceKey.self) { heights in
                    measuredHeaderHeights.merge(heights) { _, new in new }
                }
            }
        }
    }

    @ViewBuilder
    private func locationTile(_ location: BoardLocationNode) -> some View {
        if let position = layout.positions[location.id] {
            let id = BoardFocusID.location(location.id)
            let tileSize = BoardLocationTileGeometryPlan.plan(
                zoomScale: zoomScale,
                hasLinkedEnemyActions: boardHasLinkedEnemyActions,
                metrics: .current
            ).tileSize
            let enemies = enemiesByLocationID[location.id] ?? []
            let metrics = BoardLocationEnemyTileMetrics.current
            let linkedEnemyChoices = BoardFocusGraphBuilder.linkedEnemyChoices(
                for: enemies,
                choiceLinks: choiceLinks
            )
            let hasLinkedEnemyActions = hasFocusableLinkedEnemyActions(linkedEnemyChoices)
            let heightPlan = BoardLocationEnemyTileHeightPlan.plan(
                tileHeight: tileSize.height,
                measuredHeaderHeight: measuredHeaderHeights[location.id] ?? 0,
                hasEnemies: !enemies.isEmpty,
                hasLinkedEnemyActions: hasLinkedEnemyActions,
                metrics: metrics
            )
            VStack(spacing: metrics.verticalSpacing) {
                locationHeader(location, id: id, hasEnemies: !enemies.isEmpty)
                    .frame(maxHeight: heightPlan.headerMaxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .background { headerHeightReader(for: location.id) }
                if !enemies.isEmpty {
                    measuredLocationEnemyPanel(enemies, height: heightPlan.enemyPanelHeight)
                }
                if hasLinkedEnemyActions {
                    linkedEnemyActionsControl(
                        location: location,
                        linkedChoices: linkedEnemyChoices
                    )
                }
            }
            .frame(
                width: tileSize.width,
                height: tileSize.height,
                alignment: enemies.isEmpty ? .center : .top
            )
            .position(center(for: position))
        }
    }

    private func hasFocusableLinkedEnemyActions(_ linkedChoices: [BoardLinkedChoice]) -> Bool {
        switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
        case .submit, .menu:
            true
        case .highlightOnly:
            false
        }
    }

    private func linkedEnemyActionsControl(
        location: BoardLocationNode,
        linkedChoices: [BoardLinkedChoice]
    ) -> some View {
        BoardLinkedEnemyActionsControl(
            title: BoardLocalization.localized("board.enemyActions.title", "Enemy actions"),
            accessibilityLabel: BoardLocalization.format(
                "board.enemyActions.accessibility",
                "Enemy prompt actions at %@",
                location.displayLabel
            ),
            focusID: BoardFocusID.locationEnemyActions(location.id),
            linkedChoices: linkedChoices,
            focusedID: focusedID,
            focusBinding: focusBinding,
            onOutcome: onOutcome
        )
    }

    private func locationHeader(
        _ location: BoardLocationNode,
        id: SemanticFocusID,
        hasEnemies: Bool
    ) -> some View {
        BoardEntityTile(
            id: id,
            accessibilityLabel: BoardAccessibility.summary(location: location),
            isFocused: focusedID == id,
            focusBinding: focusBinding,
            onOutcome: onOutcome
        ) {
            locationTileContent(location, hasEnemies: hasEnemies)
        }
    }

    private func headerHeightReader(for locationID: LocationID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: BoardLocationHeaderHeightPreferenceKey.self,
                value: [locationID: proxy.size.height]
            )
        }
    }

    private func measuredLocationEnemyPanel(
        _ enemies: [BoardEnemyNode],
        height: CGFloat
    ) -> some View {
        GeometryReader { proxy in
            locationEnemyPanel(enemies, width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: height, alignment: .top)
        .clipped()
    }

    private func locationTileContent(
        _ location: BoardLocationNode,
        hasEnemies: Bool
    ) -> some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: hasEnemies ? 2 : 4) {
                locationTitle(location, hasEnemies: hasEnemies)
                HStack(spacing: 4) {
                    BoardStatBadge(systemImage: "sparkles", value: "\(location.clueCount)")
                    if location.enemyCount > 0 {
                        BoardStatBadge(systemImage: "figure.walk", value: "\(location.enemyCount)")
                    }
                    if !location.investigatorIDs.isEmpty {
                        BoardStatBadge(
                            systemImage: "person.fill",
                            value: "\(location.investigatorIDs.count)"
                        )
                    }
                }
            }
            locationTitle(location, hasEnemies: hasEnemies)
        }
        .accessibilityElement(children: .contain)
    }

    private func locationTitle(
        _ location: BoardLocationNode,
        hasEnemies: Bool
    ) -> some View {
        Text(location.displayLabel)
            .font(.subheadline.bold())
            .lineLimit(hasEnemies ? 1 : 2)
            .minimumScaleFactor(hasEnemies ? 0.75 : 1)
            .truncationMode(.tail)
            .multilineTextAlignment(.center)
            .foregroundStyle(ArkhamTheme.bone)
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
        case .compactIndicator:
            BoardEnemyOverflowMenu(
                label: "\(enemies.count)",
                labelStyle: .compactBadge,
                enemies: enemies,
                choiceLinks: choiceLinks,
                onLinkedChoice: onLinkedChoice
            )
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

// swiftlint:enable type_body_length

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
        let enemies = enemiesByLocationID[location.id] ?? []
        let linkedEnemyChoices = BoardFocusGraphBuilder.linkedEnemyChoices(
            for: enemies,
            choiceLinks: choiceLinks
        )
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
            if !enemies.isEmpty {
                BoardEnemyCompactPanelView(
                    title: "Enemies",
                    enemies: enemies,
                    visibleCount: 3,
                    choiceLinks: choiceLinks,
                    onLinkedChoice: onLinkedChoice
                )
            }
            enemyLocationActionsControl(location: location, linkedChoices: linkedEnemyChoices)
        }
        .accessibilityElement(children: .contain)
    }

    private func enemyLocationActionsControl(
        location: BoardEnemyLocationNode,
        linkedChoices: [BoardLinkedChoice]
    ) -> some View {
        BoardLinkedEnemyActionsControl(
            title: BoardLocalization.localized("board.enemyActions.title", "Enemy actions"),
            accessibilityLabel: BoardLocalization.format(
                "board.enemyActions.accessibility",
                "Enemy prompt actions at %@",
                location.displayLabel
            ),
            focusID: BoardFocusID.enemyLocationEnemyActions(location.id),
            linkedChoices: linkedChoices,
            focusedID: focusedID,
            focusBinding: focusBinding,
            onOutcome: onOutcome
        )
    }
}
