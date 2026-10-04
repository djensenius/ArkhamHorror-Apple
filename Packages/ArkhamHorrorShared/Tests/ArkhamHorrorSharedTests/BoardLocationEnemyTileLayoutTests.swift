@testable import ArkhamHorrorShared
import CoreGraphics
import Testing

@Suite("Board location enemy tile layout")
struct BoardLocationEnemyTileLayoutTests {
    @Test("Minimum zoom can reserve room for an enemy action control")
    func minimumZoomCanReserveRoomForEnemyActionControl() {
        #expect(
            BoardLocationEnemyTileMetrics.regular.minimumCellSize
                == CGSize(width: 90, height: 70)
        )
        #expect(
            BoardLocationEnemyTileMetrics.regular.minimumCellSize(hasLinkedEnemyActions: true)
                == CGSize(width: 90, height: 92)
        )
        #expect(
            BoardLocationEnemyTileMetrics.tvOS.minimumCellSize(hasLinkedEnemyActions: true)
                == CGSize(width: 180, height: 160)
        )
    }

    @Test("Zoom 0.5 still leaves room for an actionable compact enemy indicator")
    func zoomHalfShowsCompactIndicator() {
        #expect(
            decision(zoom: 0.5, headerHeight: 44, enemyCount: 3, metrics: .regular)
                == .compactIndicator
        )
    }

    @Test("Zoom 0.5 offers natural name box height, then reports the clipped height")
    func zoomHalfClampsNaturalNameBoxHeight() {
        let tileGeometry = BoardLocationTileGeometryPlan.plan(
            zoomScale: 0.5,
            hasLinkedEnemyActions: false,
            metrics: .regular
        )
        #expect(tileGeometry.cellSize == CGSize(width: 90, height: 70))
        #expect(tileGeometry.tileSize == CGSize(width: 82, height: 62))

        let uncappedPlan = BoardLocationEnemyTileHeightPlan.plan(
            tileHeight: tileGeometry.tileSize.height,
            measuredHeaderHeight: 86,
            hasEnemies: true,
            hasLinkedEnemyActions: false,
            metrics: .regular
        )
        let drawnHeaderHeight = BoardLocationHeaderSizing.drawnHeight(
            naturalHeight: 86,
            maximumHeight: uncappedPlan.headerMaxHeight
        )
        #expect(uncappedPlan.headerMaxHeight == BoardLocationHeaderSizing.minimumInteractiveHeight)
        #expect(drawnHeaderHeight == BoardLocationHeaderSizing.minimumInteractiveHeight)

        let measuredPlan = BoardLocationEnemyTileHeightPlan.plan(
            tileHeight: tileGeometry.tileSize.height,
            measuredHeaderHeight: drawnHeaderHeight,
            hasEnemies: true,
            hasLinkedEnemyActions: false,
            metrics: .regular
        )
        #expect(measuredPlan.effectiveHeaderHeight == drawnHeaderHeight)
        #expect(measuredPlan.enemyPanelHeight == 14)
    }

    @Test("Zoom 1 with a measured one-line header shows one chip and overflow")
    func zoomOneOneLineHeaderShowsChipAndOverflow() {
        #expect(
            decision(zoom: 1, headerHeight: 66, enemyCount: 3, metrics: .regular)
                == .chips(visibleCount: 1, hasMore: true)
        )
    }

    @Test("Zoom 1 with a measured two-line header falls back instead of clipping chips")
    func zoomOneTwoLineHeaderShowsCompactIndicator() {
        #expect(
            decision(zoom: 1, headerHeight: 86, enemyCount: 3, metrics: .regular)
                == .compactIndicator
        )
    }

    @Test("Zoom 3 has enough measured space for all compact chips")
    func zoomThreeShowsAllChips() {
        #expect(
            decision(zoom: 3, headerHeight: 86, enemyCount: 3, metrics: .regular)
                == .chips(visibleCount: 3, hasMore: false)
        )
    }

    @Test("tvOS one-line measured header leaves room for chip plus overflow")
    func tvOSOneLineHeaderShowsChipAndOverflow() {
        #expect(
            decision(zoom: 1, headerHeight: 95, enemyCount: 3, metrics: .tvOS)
                == .chips(visibleCount: 1, hasMore: true)
        )
    }

    @Test("tvOS two-line measured header still leaves an actionable compact indicator")
    func tvOSTwoLineHeaderShowsCompactIndicator() {
        #expect(
            decision(zoom: 1, headerHeight: 126, enemyCount: 3, metrics: .tvOS)
                == .compactIndicator
        )
    }

    @Test("tvOS minimum cell with linked action still leaves compact indicator room")
    func tvOSMinimumCellWithLinkedActionShowsCompactIndicator() {
        #expect(
            decision(
                zoom: 1,
                headerHeight: 126,
                enemyCount: 3,
                metrics: .tvOS,
                hasLinkedEnemyActions: true
            ) == .compactIndicator
        )
    }

    private func decision(
        zoom: CGFloat,
        headerHeight: CGFloat,
        enemyCount: Int,
        metrics: BoardLocationEnemyTileMetrics,
        hasLinkedEnemyActions: Bool = false
    ) -> BoardLocationEnemyTileLayoutDecision {
        let tileGeometry = BoardLocationTileGeometryPlan.plan(
            zoomScale: zoom,
            hasLinkedEnemyActions: hasLinkedEnemyActions,
            metrics: metrics
        )
        let uncappedPlan = BoardLocationEnemyTileHeightPlan.plan(
            tileHeight: tileGeometry.tileSize.height,
            measuredHeaderHeight: headerHeight,
            hasEnemies: enemyCount > 0,
            hasLinkedEnemyActions: hasLinkedEnemyActions,
            metrics: metrics
        )
        let drawnHeaderHeight = BoardLocationHeaderSizing.drawnHeight(
            naturalHeight: headerHeight,
            maximumHeight: uncappedPlan.headerMaxHeight
        )
        let heightPlan = BoardLocationEnemyTileHeightPlan.plan(
            tileHeight: tileGeometry.tileSize.height,
            measuredHeaderHeight: drawnHeaderHeight,
            hasEnemies: enemyCount > 0,
            hasLinkedEnemyActions: hasLinkedEnemyActions,
            metrics: metrics
        )
        return BoardLocationEnemyTileLayout.decision(
            enemyCount: enemyCount,
            availableWidth: tileGeometry.tileSize.width,
            availableHeight: heightPlan.enemyPanelHeight,
            metrics: metrics
        )
    }
}
