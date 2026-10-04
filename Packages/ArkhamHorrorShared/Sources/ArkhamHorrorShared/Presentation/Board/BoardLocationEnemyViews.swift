import SwiftUI

/// Point-based constants for the compact enemy affordances inside a location tile.
/// These values are deliberately smaller than full card art: they preserve prompt
/// reachability when the board is zoomed out while still leaving enough room for the
/// location name box to remain the primary content of the tile.
struct BoardLocationEnemyTileMetrics: Sendable, Equatable {
    /// Height of a rendered one-line enemy chip.
    let chipRowHeight: CGFloat
    /// Height of the all-enemies summary button such as "3 enemies".
    let summaryButtonHeight: CGFloat
    /// Height of the smallest tappable/count indicator used at minimum zoom.
    let compactIndicatorHeight: CGFloat
    /// Minimum width for a chip before the layout switches to an overflow affordance.
    let chipMinWidth: CGFloat
    /// Minimum width for a text overflow button.
    let moreButtonMinWidth: CGFloat
    /// Minimum width for the compact count badge.
    let compactIndicatorMinWidth: CGFloat
    /// Minimum grid cell size before subtracting ``BoardLocationTileGeometryPlan/tileGutter``.
    let minimumCellSize: CGSize
    /// Horizontal spacing between chips and overflow controls.
    let horizontalSpacing: CGFloat
    /// Vertical spacing between the location header, enemy panel, and action control.
    let verticalSpacing: CGFloat

    /// Pointer/touch platforms can use a tighter board: text is near the player and the
    /// prompt panel remains available as a redundant action path.
    static let regular = BoardLocationEnemyTileMetrics(
        chipRowHeight: 24,
        summaryButtonHeight: 18,
        compactIndicatorHeight: 14,
        chipMinWidth: 70,
        moreButtonMinWidth: 48,
        compactIndicatorMinWidth: 24,
        minimumCellSize: CGSize(width: 90, height: 70),
        horizontalSpacing: 4,
        verticalSpacing: 4
    )
    /// tvOS uses a 180×160 minimum so the location name box, compact enemy count,
    /// and optional enemy-actions control remain legible from the couch after the
    /// 4pt-per-edge tile gutter is removed; smaller cells hid the indicator at
    /// minimum zoom on Siri Remote/controller layouts.
    static let tvOS = BoardLocationEnemyTileMetrics(
        chipRowHeight: 32,
        summaryButtonHeight: 22,
        compactIndicatorHeight: 20,
        chipMinWidth: 86,
        moreButtonMinWidth: 64,
        compactIndicatorMinWidth: 40,
        minimumCellSize: CGSize(width: 180, height: 160),
        horizontalSpacing: 6,
        verticalSpacing: 6
    )

    static var current: BoardLocationEnemyTileMetrics {
        #if os(tvOS)
            tvOS
        #else
            regular
        #endif
    }

    func minimumCellSize(hasLinkedEnemyActions: Bool) -> CGSize {
        guard hasLinkedEnemyActions else { return minimumCellSize }
        let minimumTileHeight = BoardLocationHeaderSizing.minimumInteractiveHeight
            + compactIndicatorHeight + summaryButtonHeight + (2 * verticalSpacing)
        return CGSize(
            width: minimumCellSize.width,
            height: max(minimumCellSize.height, minimumTileHeight + BoardLocationTileGeometryPlan.tileGutter)
        )
    }
}

enum BoardLocationHeaderSizing {
    /// Matches ``BoardEntityTile``'s 44pt minimum touch/focus target. Enemy layout may
    /// compress a location header down to this height, but never below it.
    static let minimumInteractiveHeight: CGFloat = 44

    static func drawnHeight(naturalHeight: CGFloat, maximumHeight: CGFloat?) -> CGFloat {
        guard let maximumHeight else { return naturalHeight }
        return min(naturalHeight, maximumHeight)
    }
}

struct BoardLocationHeaderClampLayout: Layout {
    let maximumHeight: CGFloat?

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let naturalSize = subview.sizeThatFits(.init(width: proposal.width, height: nil))
        return CGSize(
            width: proposal.width ?? naturalSize.width,
            height: BoardLocationHeaderSizing.drawnHeight(
                naturalHeight: naturalSize.height,
                maximumHeight: maximumHeight
            )
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: .init(width: bounds.width, height: nil)
        )
    }
}

struct BoardLocationTileGeometryPlan: Sendable, Equatable {
    /// The unzoomed board cell size inherited from the original PR #79 layout.
    static let baseCellSize = CGSize(width: 150, height: 112)
    /// Total per-axis gutter between neighboring cells; each tile is inset by 4pt per edge.
    static let tileGutter: CGFloat = 8

    /// Grid cell size used for positioning and drawing connection lines.
    let cellSize: CGSize
    /// Actual tile size inside the cell after the gutter is reserved.
    let tileSize: CGSize

    static func plan(
        zoomScale: CGFloat,
        hasLinkedEnemyActions: Bool,
        metrics: BoardLocationEnemyTileMetrics
    ) -> BoardLocationTileGeometryPlan {
        let minimumCellSize = metrics.minimumCellSize(
            hasLinkedEnemyActions: hasLinkedEnemyActions
        )
        let cellSize = CGSize(
            width: max(baseCellSize.width * zoomScale, minimumCellSize.width),
            height: max(baseCellSize.height * zoomScale, minimumCellSize.height)
        )
        let tileSize = CGSize(
            width: max(cellSize.width - tileGutter, 0),
            height: max(cellSize.height - tileGutter, 0)
        )
        return BoardLocationTileGeometryPlan(cellSize: cellSize, tileSize: tileSize)
    }
}

struct BoardLocationEnemyTileHeightPlan: Sendable, Equatable {
    let headerMaxHeight: CGFloat?
    let effectiveHeaderHeight: CGFloat
    let enemyPanelHeight: CGFloat

    static func plan(
        tileHeight: CGFloat,
        measuredHeaderHeight: CGFloat,
        hasEnemies: Bool,
        hasLinkedEnemyActions: Bool,
        metrics: BoardLocationEnemyTileMetrics
    ) -> BoardLocationEnemyTileHeightPlan {
        guard hasEnemies else {
            return BoardLocationEnemyTileHeightPlan(
                headerMaxHeight: nil,
                effectiveHeaderHeight: measuredHeaderHeight,
                enemyPanelHeight: 0
            )
        }
        let linkedEnemyActionsHeight = hasLinkedEnemyActions
            ? metrics.summaryButtonHeight + metrics.verticalSpacing
            : 0
        let headerMaxHeight = max(
            tileHeight - metrics.compactIndicatorHeight - metrics.verticalSpacing
                - linkedEnemyActionsHeight,
            BoardLocationHeaderSizing.minimumInteractiveHeight
        )
        let effectiveHeaderHeight = min(measuredHeaderHeight, headerMaxHeight)
        let enemyPanelHeight = max(
            tileHeight - effectiveHeaderHeight - metrics.verticalSpacing - linkedEnemyActionsHeight,
            0
        )
        return BoardLocationEnemyTileHeightPlan(
            headerMaxHeight: headerMaxHeight,
            effectiveHeaderHeight: effectiveHeaderHeight,
            enemyPanelHeight: enemyPanelHeight
        )
    }
}

enum BoardLocationEnemyTileLayoutDecision: Sendable, Equatable {
    case hidden
    case compactIndicator
    case summaryButton
    case chips(visibleCount: Int, hasMore: Bool)
}

enum BoardLocationEnemyTileLayout {
    static func decision(
        enemyCount: Int,
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        metrics: BoardLocationEnemyTileMetrics
    ) -> BoardLocationEnemyTileLayoutDecision {
        guard enemyCount > 0,
              availableHeight >= metrics.compactIndicatorHeight,
              availableWidth >= metrics.compactIndicatorMinWidth
        else { return .hidden }
        guard availableHeight >= metrics.summaryButtonHeight,
              availableWidth >= metrics.moreButtonMinWidth
        else { return .compactIndicator }
        guard availableHeight >= metrics.chipRowHeight,
              availableWidth >= metrics.chipMinWidth
        else { return .summaryButton }
        let slotsWithoutOverflow = chipSlots(
            availableWidth: availableWidth,
            metrics: metrics
        )
        guard slotsWithoutOverflow > 0 else { return .summaryButton }
        if enemyCount <= slotsWithoutOverflow {
            return .chips(visibleCount: enemyCount, hasMore: false)
        }
        let overflowWidth = metrics.moreButtonMinWidth + metrics.horizontalSpacing
        let slotsWithOverflow = chipSlots(
            availableWidth: availableWidth - overflowWidth,
            metrics: metrics
        )
        guard slotsWithOverflow > 0 else { return .summaryButton }
        return .chips(visibleCount: min(enemyCount, slotsWithOverflow), hasMore: true)
    }

    private static func chipSlots(
        availableWidth: CGFloat,
        metrics: BoardLocationEnemyTileMetrics
    ) -> Int {
        guard availableWidth >= metrics.chipMinWidth else { return 0 }
        let slotWidth = metrics.chipMinWidth + metrics.horizontalSpacing
        return max(Int((availableWidth + metrics.horizontalSpacing) / slotWidth), 0)
    }
}

struct BoardLinkedEnemyActionsControl: View {
    let title: String
    let accessibilityLabel: String
    let focusID: SemanticFocusID
    let linkedChoices: [BoardLinkedChoice]
    let focusedID: SemanticFocusID?
    let focusBinding: FocusState<SemanticFocusID?>.Binding
    let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void

    var body: some View {
        let decision = BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices)
        switch decision {
        case .highlightOnly:
            EmptyView()
        case .submit, .menu:
            SemanticActionControl(
                accessibilityLabel: Text(accessibilityLabel),
                semanticFocusID: focusID,
                onOutcome: onOutcome,
                label: {
                    Label(title, systemImage: "figure.walk")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    focusedID == focusID ? ArkhamTheme.accent : Color.clear,
                                    lineWidth: 3
                                )
                        }
                }
            )
            .buttonStyle(.plain)
            .accessibilityHint(Text(Self.accessibilityHint(for: decision)))
            .focused(focusBinding, equals: focusID)
        }
    }

    static func accessibilityHint(for decision: BoardLinkedChoicePresentationDecision) -> String {
        switch decision {
        case let .submit(choice):
            BoardLocalization.format(
                "board.linkedChoice.activateHint",
                "Activates %@",
                choice.title
            )
        case .menu:
            BoardLocalization.localized(
                "board.linkedChoice.chooseHint",
                "Choose which prompt action to take."
            )
        case .highlightOnly:
            ""
        }
    }
}

struct BoardEnemyCompactPanelView: View {
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
                BoardEnemyOverflowMenu(
                    label: "+\(enemies.count - visibleCount) more enemies",
                    enemies: enemies,
                    choiceLinks: choiceLinks,
                    onLinkedChoice: onLinkedChoice
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum BoardEnemyOverflowLabelStyle {
    case text
    case compactBadge
}

struct BoardEnemyOverflowMenu: View {
    let label: String
    var labelStyle: BoardEnemyOverflowLabelStyle = .text
    let enemies: [BoardEnemyNode]
    let choiceLinks: [BoardPromptElementID: [BoardLinkedChoice]]
    let onLinkedChoice: (Int) -> Void
    @Environment(\.boardCardCatalog) private var cardCatalog

    var body: some View {
        Menu {
            ForEach(enemies) { enemy in
                let linkedChoices = choiceLinks[.enemy(enemy.id)] ?? []
                switch BoardLinkedChoicePresentationPolicy.decision(for: linkedChoices) {
                case .highlightOnly:
                    Text(menuSummary(enemy, linkedChoices: linkedChoices))
                case let .submit(choice):
                    Button("\(menuSummary(enemy, linkedChoices: linkedChoices)): \(choice.title)") {
                        onLinkedChoice(choice.choiceIndex)
                    }
                case let .menu(actionableChoices):
                    Menu(menuSummary(enemy, linkedChoices: linkedChoices)) {
                        ForEach(actionableChoices, id: \.choiceIndex) { choice in
                            Button(choice.title) { onLinkedChoice(choice.choiceIndex) }
                        }
                    }
                }
            }
        } label: {
            switch labelStyle {
            case .text:
                Text(label)
                    .font(.caption2.bold())
                    .foregroundStyle(ArkhamTheme.accent)
            case .compactBadge:
                Label(label, systemImage: "figure.walk")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.25), in: Capsule())
                    .foregroundStyle(ArkhamTheme.accent)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(Text("Show all \(enemies.count) enemies"))
    }

    private func menuSummary(
        _ enemy: BoardEnemyNode,
        linkedChoices: [BoardLinkedChoice]
    ) -> String {
        let displayName = enemy.cardCode.flatMap { cardCatalog?.displayName(for: $0) }
            ?? enemy.displayName
        let summary = BoardEnemyCompactFormatting.listSummary(enemy, displayName: displayName)
        guard !linkedChoices.isEmpty else { return summary }
        return linkedChoices.contains(where: \.isActionable)
            ? "\(summary) — prompt action"
            : "\(summary) — prompt unavailable"
    }
}
