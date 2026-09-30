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
            let summaryHeight = enemies.isEmpty ? tileSize.height : min(48, tileSize.height * 0.46)
            VStack(spacing: 6) {
                BoardEntityTile(
                    id: id,
                    accessibilityLabel: BoardAccessibility.summary(location: location),
                    isFocused: focusedID == id,
                    focusBinding: focusBinding,
                    onOutcome: onOutcome
                ) {
                    locationTileContent(location)
                }
                .frame(width: tileSize.width, height: summaryHeight)
                locationEnemyPanel(enemies)
            }
            .frame(width: tileSize.width, height: tileSize.height, alignment: .top)
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
    private func locationEnemyPanel(_ enemies: [BoardEnemyNode]) -> some View {
        if !enemies.isEmpty {
            BoardEnemyCompactPanelView(
                title: "Enemies",
                enemies: enemies,
                visibleCount: 2,
                choiceLinks: choiceLinks,
                onLinkedChoice: onLinkedChoice
            )
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

private struct BoardEnemyCompactPanelView: View {
    let title: String
    let enemies: [BoardEnemyNode]
    let visibleCount: Int
    let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    let onLinkedChoice: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            ForEach(Array(enemies.prefix(visibleCount))) { enemy in
                BoardEnemyCompactChipView(
                    enemy: enemy,
                    linkedChoices: choiceLinks[.enemy(enemy.id)] ?? [],
                    onLinkedChoice: onLinkedChoice
                )
            }
            if enemies.count > visibleCount {
                Menu {
                    ForEach(enemies) { enemy in
                        Text(BoardEnemyCompactFormatting.listSummary(enemy))
                    }
                } label: {
                    Text("+\(enemies.count - visibleCount) more enemies")
                        .font(.caption2.bold())
                        .foregroundStyle(ArkhamTheme.accent)
                }
                .accessibilityLabel(Text("Show all \(enemies.count) enemies"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BoardEnemyCompactChipView: View {
    let enemy: BoardEnemyNode
    let linkedChoices: [BoardLinkedChoice]
    let onLinkedChoice: (Int) -> Void
    @Environment(\.boardCardCatalog) private var cardCatalog

    private var displayName: String {
        enemy.cardCode.flatMap { cardCatalog?.displayName(for: $0) } ?? enemy.displayName
    }

    private var actionableChoices: [BoardLinkedChoice] {
        linkedChoices.filter(\.isActionable)
    }

    var body: some View {
        switch actionableChoices.count {
        case 0:
            chip
        case 1:
            if let choice = actionableChoices.first {
                Button { onLinkedChoice(choice.choiceIndex) } label: { chip }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Activates \(choice.title)"))
            }
        default:
            Menu {
                ForEach(actionableChoices, id: \.choiceIndex) { choice in
                    Button(choice.title) { onLinkedChoice(choice.choiceIndex) }
                }
            } label: {
                chip
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityHint(Text("Choose which prompt action to take."))
        }
    }

    private var chip: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayName)
                .font(.caption2.bold())
                .lineLimit(1)
                .foregroundStyle(ArkhamTheme.bone)
            Text(BoardEnemyCompactFormatting.statsSummary(enemy))
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(outlineColor, lineWidth: linkedChoices.isEmpty ? 1 : 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(BoardAccessibility.summary(enemy: enemy)))
    }

    private var outlineColor: Color {
        guard !linkedChoices.isEmpty else { return .white.opacity(0.12) }
        return actionableChoices.isEmpty ? .orange.opacity(0.45) : ArkhamTheme.accent
    }
}

private enum BoardEnemyCompactFormatting {
    static func statsSummary(_ enemy: BoardEnemyNode) -> String {
        var parts: [String] = []
        if let fight = enemy.fight {
            parts.append("F \(fight.displayValue)")
        }
        if let health = enemy.health {
            parts.append("H \(health.displayValue)")
        }
        if let evade = enemy.evade {
            parts.append("E \(evade.displayValue)")
        }
        if let damage = enemy.damage, damage > 0 {
            parts.append("Dmg \(damage)")
        }
        return parts.isEmpty ? "Enemy" : parts.joined(separator: "  ")
    }

    static func listSummary(_ enemy: BoardEnemyNode) -> String {
        "\(enemy.displayName): \(statsSummary(enemy))"
    }
}
