@testable import ArkhamHorrorShared
import CoreGraphics
import Testing

@Suite("Board location enemy tile layout")
struct BoardLocationEnemyTileLayoutTests {
    @Test("Zoom 0.5 still leaves room for an actionable compact enemy indicator")
    func zoomHalfShowsCompactIndicator() {
        #expect(
            decision(zoom: 0.5, headerHeight: 44, enemyCount: 3, metrics: .regular)
                == .compactIndicator
        )
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

    private func decision(
        zoom: CGFloat,
        headerHeight: CGFloat,
        enemyCount: Int,
        metrics: BoardLocationEnemyTileMetrics
    ) -> BoardLocationEnemyTileLayoutDecision {
        let tileWidth = max(150 * zoom, metrics.minimumCellSize.width) - 8
        let tileHeight = max(112 * zoom, metrics.minimumCellSize.height) - 8
        let availableHeight = max(tileHeight - headerHeight - metrics.verticalSpacing, 0)
        return BoardLocationEnemyTileLayout.decision(
            enemyCount: enemyCount,
            availableWidth: tileWidth,
            availableHeight: availableHeight,
            metrics: metrics
        )
    }
}
