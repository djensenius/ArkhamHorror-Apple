@testable import ArkhamHorrorShared
import Testing

/// Coverage for
/// ``BoardFocusGraphBuilder/resolveCompactSelectedZone(focusedZone:preModalZone:zones:)``,
/// the pure decision behind ``BoardCompactLayoutView``'s zone switcher `Picker` selection.
@Suite("BoardFocusGraphBuilder — compact zone switcher selection")
struct BoardCompactZoneSelectionTests {
    @Test("A focused zone that is one of the switcher's own tags is returned unchanged")
    func focusedZoneAmongTagsIsReturnedUnchanged() {
        let zones = [BoardFocusZone.scenario, BoardFocusZone.locations, BoardFocusZone.chaosBag]
        let resolved = BoardFocusGraphBuilder.resolveCompactSelectedZone(
            focusedZone: BoardFocusZone.locations, preModalZone: nil, zones: zones
        )
        #expect(resolved == BoardFocusZone.locations)
    }

    @Test(
        """
        A focused zone outside the switcher's tags (board.inspector while the inspector \
        modal is presented) with no remembered pre-modal zone falls back to the first \
        tag, never an untagged value
        """
    )
    func focusedZoneOutsideTagsWithNoPreModalZoneFallsBackToFirstZone() {
        let zones = [BoardFocusZone.scenario, BoardFocusZone.locations, BoardFocusZone.chaosBag]
        let resolved = BoardFocusGraphBuilder.resolveCompactSelectedZone(
            focusedZone: BoardFocusZone.inspector, preModalZone: nil, zones: zones
        )
        #expect(resolved == BoardFocusZone.scenario)
        #expect(zones.contains(resolved))
    }

    @Test(
        """
        While the inspector modal is presented (focusedZone is board.inspector), a still-\
        valid remembered pre-modal zone is preferred over arbitrarily the first tag
        """
    )
    func focusedZoneOutsideTagsPrefersValidPreModalZone() {
        let zones = [BoardFocusZone.scenario, BoardFocusZone.locations, BoardFocusZone.chaosBag]
        let resolved = BoardFocusGraphBuilder.resolveCompactSelectedZone(
            focusedZone: BoardFocusZone.inspector, preModalZone: BoardFocusZone.chaosBag,
            zones: zones
        )
        #expect(resolved == BoardFocusZone.chaosBag)
    }

    @Test(
        """
        A remembered pre-modal zone that is no longer among the switcher's tags (its last \
        entity was removed by an intervening snapshot while the modal was open) falls \
        back to the first tag rather than an untagged value
        """
    )
    func preModalZoneNoLongerValidFallsBackToFirstZone() {
        let zones = [BoardFocusZone.scenario, BoardFocusZone.locations]
        let resolved = BoardFocusGraphBuilder.resolveCompactSelectedZone(
            focusedZone: BoardFocusZone.inspector, preModalZone: BoardFocusZone.chaosBag,
            zones: zones
        )
        #expect(resolved == BoardFocusZone.scenario)
    }

    @Test("A nil focused zone falls back to the first tag")
    func nilFocusedZoneFallsBackToFirstZone() {
        let zones = [BoardFocusZone.locations, BoardFocusZone.chaosBag]
        let resolved = BoardFocusGraphBuilder.resolveCompactSelectedZone(
            focusedZone: nil, preModalZone: nil, zones: zones
        )
        #expect(resolved == BoardFocusZone.locations)
    }

    @Test("An empty zones array falls back to board.scenario rather than trapping")
    func emptyZonesFallsBackToScenario() {
        let resolved = BoardFocusGraphBuilder.resolveCompactSelectedZone(
            focusedZone: BoardFocusZone.inspector, preModalZone: BoardFocusZone.locations,
            zones: []
        )
        #expect(resolved == BoardFocusZone.scenario)
    }
}
