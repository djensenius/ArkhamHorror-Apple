@testable import ArkhamHorrorShared
import CoreGraphics
import Testing

@Suite("Board location enemy tile layout")
struct BoardLocationEnemyTileLayoutTests {
    @Test("Zoom 0.5 has no room after the unsqueezed location header")
    func zoomHalfHidesEnemyRow() {
        #expect(decision(zoom: 0.5, enemyCount: 3, metrics: .regular) == .hidden)
    }

    @Test("Zoom 1 shows one compact chip and an actionable overflow control")
    func zoomOneShowsChipAndOverflow() {
        #expect(
            decision(zoom: 1, enemyCount: 3, metrics: .regular)
                == .chips(visibleCount: 1, hasMore: true)
        )
    }

    @Test("tvOS metrics fall back to the all-enemies control instead of overflowing")
    func tvOSMetricsUseSummaryButtonWhenChipRowDoesNotFit() {
        #expect(decision(zoom: 1, enemyCount: 3, metrics: .tvOS) == .summaryButton)
    }

    private func decision(
        zoom: CGFloat,
        enemyCount: Int,
        metrics: BoardLocationEnemyTileMetrics
    ) -> BoardLocationEnemyTileLayoutDecision {
        let tileWidth = (150 * zoom) - 8
        let tileHeight = (112 * zoom) - 8
        let availableHeight = max(
            tileHeight - metrics.headerReservedHeight - metrics.verticalSpacing,
            0
        )
        return BoardLocationEnemyTileLayout.decision(
            enemyCount: enemyCount,
            availableWidth: tileWidth,
            availableHeight: availableHeight,
            metrics: metrics
        )
    }
}
