@testable import ArkhamHorrorShared
import Testing

/// Coverage for ``BoardFocusGraphBuilder/resolveCompactSelectedZone(focusedZone:zones:)``,
/// the pure decision behind ``BoardCompactLayoutView``'s zone switcher `Picker` selection.
@Suite("BoardFocusGraphBuilder — compact zone switcher selection")
struct BoardCompactZoneSelectionTests {
    @Test("A focused zone that is one of the switcher's own tags is returned unchanged")
    func focusedZoneAmongTagsIsReturnedUnchanged() {
        let zones = [BoardFocusZone.scenario, BoardFocusZone.locations, BoardFocusZone.chaosBag]
        let resolved = BoardFocusGraphBuilder.resolveCompactSelectedZone(
            focusedZone: BoardFocusZone.locations, zones: zones
        )
        #expect(resolved == BoardFocusZone.locations)
    }

    @Test(
        """
        A focused zone outside the switcher's tags (for example board.inspector while the \
        inspector modal is presented) falls back to the first tag, never an untagged value
        """
    )
    func focusedZoneOutsideTagsFallsBackToFirstZone() {
        let zones = [BoardFocusZone.scenario, BoardFocusZone.locations, BoardFocusZone.chaosBag]
        let resolved = BoardFocusGraphBuilder.resolveCompactSelectedZone(
            focusedZone: BoardFocusZone.inspector, zones: zones
        )
        #expect(resolved == BoardFocusZone.scenario)
        #expect(zones.contains(resolved))
    }

    @Test("A nil focused zone falls back to the first tag")
    func nilFocusedZoneFallsBackToFirstZone() {
        let zones = [BoardFocusZone.locations, BoardFocusZone.chaosBag]
        let resolved = BoardFocusGraphBuilder.resolveCompactSelectedZone(
            focusedZone: nil, zones: zones
        )
        #expect(resolved == BoardFocusZone.locations)
    }

    @Test("An empty zones array falls back to board.scenario rather than trapping")
    func emptyZonesFallsBackToScenario() {
        let resolved = BoardFocusGraphBuilder.resolveCompactSelectedZone(
            focusedZone: BoardFocusZone.inspector, zones: []
        )
        #expect(resolved == BoardFocusZone.scenario)
    }
}
