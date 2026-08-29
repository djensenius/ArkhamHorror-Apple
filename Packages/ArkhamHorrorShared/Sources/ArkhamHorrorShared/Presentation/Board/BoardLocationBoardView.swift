import SwiftUI

/// The ordinary-location board — the board's single "board.locations" zone, laid out from
/// ``BoardLayout``'s deterministic grid positions. Connections are drawn as a
/// noninteractive, accessibility-hidden ``Canvas`` decoration behind the location tiles;
/// every tile itself remains an independent focusable/accessible view.
struct BoardLocationBoardView: View {
    let locations: [BoardLocationNode]
    let layout: BoardLayout
    let zoomScale: CGFloat
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void

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
                width: baseCellSize.width * zoomScale * 0.85,
                height: baseCellSize.height * zoomScale * 0.85
            )
            BoardEntityTile(
                id: id,
                accessibilityLabel: BoardAccessibility.summary(location: location),
                isFocused: focusedID == id,
                focusBinding: focusBinding,
                onOutcome: onOutcome
            ) {
                locationTileContent(location)
            }
            .frame(width: tileSize.width, height: tileSize.height)
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
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void

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
        return BoardEntityTile(
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
                            systemImage: "person.fill", value: "\(location.investigatorIDs.count)"
                        )
                    }
                }
            }
        }
    }
}
