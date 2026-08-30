@testable import ArkhamHorrorShared
import Testing

/// Integration coverage for ``BoardCommandController/preModalZone``: the compact-width
/// zone switcher must stay parked on whatever zone was selected before the inspector
/// modal opened, for the modal's entire lifetime, and must restore deterministically —
/// including when the inspected entity's zone disappears entirely while the modal is
/// still open. Complements ``BoardCompactZoneSelectionTests``'s pure-function coverage of
/// ``BoardFocusGraphBuilder/resolveCompactSelectedZone(focusedZone:preModalZone:zones:)``
/// itself.
@MainActor
@Suite("BoardCommandController — compact switcher zone across the inspector modal")
struct BoardCompactModalZoneTests {
    private func twoLocationProjection() -> BoardProjection {
        let first = BoardTestFixtures.locationID("000000000301")
        let second = BoardTestFixtures.locationID("000000000302")
        let investigatorID = BoardTestFixtures.investigatorID("c95001")
        let snapshot = BoardTestFixtures.snapshot(
            locations: [
                (first, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: first, connectedLocations: [second], investigators: [investigatorID]
                ))),
                (second, .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: second, connectedLocations: [first]
                ))),
            ],
            investigators: [investigatorID: BoardTestFixtures.investigator(id: investigatorID)],
            playerOrder: [investigatorID],
            activeInvestigatorID: investigatorID, leadInvestigatorID: investigatorID
        )
        return BoardProjectionBuilder.makeProjection(from: snapshot)
    }

    private func resolvedSelectedZone(_ controller: BoardCommandController) -> SemanticFocusZone {
        BoardFocusGraphBuilder.resolveCompactSelectedZone(
            focusedZone: controller.focusedZone, preModalZone: controller.preModalZone,
            zones: BoardFocusGraphBuilder.nonEmptyZonesInCycleOrder(
                projection: controller.projection
            )
        )
    }

    @Test("preModalZone is nil until an inspector is actually presented")
    func preModalZoneNilBeforeInspectorOpens() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        #expect(controller.preModalZone == nil)
    }

    @Test(
        """
        Opening the inspector from the investigators zone keeps the compact switcher's \
        resolved selection on investigators for as long as the modal stays open, never \
        snapping to the first zone
        """
    )
    func openingInspectorRetainsPreModalZoneForSwitcherSelection() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        controller.selectZone(BoardFocusZone.investigators)
        #expect(resolvedSelectedZone(controller) == BoardFocusZone.investigators)

        #expect(controller.handle(.command(.inspect)))
        #expect(controller.coordinator.isModalPresented)
        // While presented, `focusedZone` itself reads as `.inspector` — never one of the
        // switcher's own tags — so retaining the pre-modal selection depends entirely on
        // `preModalZone`, not `focusedZone`.
        #expect(controller.focusedZone == BoardFocusZone.inspector)
        #expect(controller.preModalZone == BoardFocusZone.investigators)
        #expect(resolvedSelectedZone(controller) == BoardFocusZone.investigators)
    }

    @Test(
        """
        Closing the inspector restores focus to its still-mounted destination and \
        clears preModalZone
        """
    )
    func closingInspectorRestoresFocusAndClearsPreModalZone() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        controller.selectZone(BoardFocusZone.chaosBag)
        let focusBeforeOpen = controller.coordinator.currentFocus
        #expect(controller.handle(.command(.inspect)))

        #expect(controller.handle(.command(.secondaryAction)))
        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.preModalZone == nil)
        #expect(controller.coordinator.currentFocus == focusBeforeOpen)
        #expect(resolvedSelectedZone(controller) == BoardFocusZone.chaosBag)
    }

    @Test(
        """
        reservedBack (a system Menu/back gesture) closes the inspector through the same \
        path as secondaryAction, also clearing preModalZone rather than leaving it stale
        """
    )
    func reservedBackClearsPreModalZoneToo() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        controller.selectZone(BoardFocusZone.locations)
        #expect(controller.handle(.command(.inspect)))
        #expect(controller.preModalZone == BoardFocusZone.locations)

        #expect(controller.handle(.reservedBack))
        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.preModalZone == nil)
    }

    @Test(
        """
        A snapshot replacement that removes the inspected zone's only entity while the \
        modal is still open force-closes it, clears preModalZone, and the switcher \
        resolves deterministically to a zone that still exists rather than the removed one
        """
    )
    func snapshotReplacementRemovingInspectedZoneClearsPreModalZoneDeterministically() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        controller.selectZone(BoardFocusZone.investigators)
        #expect(controller.handle(.command(.inspect)))
        #expect(controller.preModalZone == BoardFocusZone.investigators)

        // A replacement snapshot with no investigators at all: the investigators zone
        // itself no longer exists in the new graph.
        let replacement = BoardTestFixtures.snapshot(
            locations: [(
                BoardTestFixtures.locationID("000000000301"),
                .ordinary(BoardTestFixtures.ordinaryLocation(
                    id: BoardTestFixtures.locationID("000000000301")
                ))
            )]
        )
        controller.applySnapshot(BoardProjectionBuilder.makeProjection(from: replacement))

        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.preModalZone == nil)
        let zones = BoardFocusGraphBuilder.nonEmptyZonesInCycleOrder(
            projection: controller.projection
        )
        #expect(zones.contains(resolvedSelectedZone(controller)))
        #expect(!zones.contains(BoardFocusZone.investigators))
    }
}
