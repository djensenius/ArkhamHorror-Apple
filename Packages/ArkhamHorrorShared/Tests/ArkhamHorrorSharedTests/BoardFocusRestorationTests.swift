@testable import ArkhamHorrorShared
import Testing

/// Continuation of ``BoardCommandControllerTests``, split into a second file purely to
/// stay under SwiftLint's type-body-length budget: focus restoration across snapshot
/// replacement (insertion, removal, reorder), including while the inspector is open.
@MainActor
@Suite("BoardCommandController — focus restoration across snapshot replacement")
struct BoardFocusRestorationTests {
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

    @Test("Focus on a removed location falls back deterministically after applySnapshot")
    func focusOnRemovedLocationFallsBackAfterSnapshot() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        controller.selectZone(BoardFocusZone.locations)
        let firstLocationID = controller.projection.locations[0].id
        #expect(controller.coordinator.currentFocus == BoardFocusID.location(firstLocationID))

        // Replace with a snapshot that no longer includes that location at all.
        let replacement = BoardTestFixtures.snapshot()
        controller.applySnapshot(BoardProjectionBuilder.makeProjection(from: replacement))
        // The locations zone no longer exists at all; focus must fall back to some
        // remaining node, never a dangling reference to the removed location.
        #expect(controller.coordinator.currentFocus != BoardFocusID.location(firstLocationID))
        #expect(controller.coordinator.currentFocus != nil)
    }

    @Test("An open inspector is closed automatically when applySnapshot replaces the graph")
    func inspectorClosesAutomaticallyOnSnapshotReplacement() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        #expect(controller.handle(.command(.inspect)))
        #expect(controller.coordinator.isModalPresented)
        controller.applySnapshot(twoLocationProjection())
        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.inspectedID == nil)
    }

    @Test(
        """
        Inspecting a location that a replacement snapshot then removes closes the \
        inspector and falls back deterministically, never stranding focus on the gone entity
        """
    )
    func inspectingRemovedLocationClosesAndFallsBackDeterministically() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        controller.selectZone(BoardFocusZone.locations)
        let inspectedLocationID = controller.projection.locations[0].id
        #expect(controller.handle(.command(.inspect)))
        #expect(controller.inspectedID == BoardFocusID.location(inspectedLocationID))
        #expect(controller.coordinator.isModalPresented)

        // Replace with a snapshot that no longer includes any locations at all — the
        // inspected entity is gone.
        let replacement = BoardTestFixtures.snapshot()
        controller.applySnapshot(BoardProjectionBuilder.makeProjection(from: replacement))

        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.inspectedID == nil)
        #expect(controller.coordinator.currentFocus != BoardFocusID.inspectorClose)
        #expect(controller.coordinator.currentFocus != BoardFocusID.location(inspectedLocationID))
        #expect(controller.coordinator.currentFocus != nil)
    }

    @Test(
        """
        Inspecting an investigator that survives an insertion-only replacement snapshot \
        closes the inspector but restores focus to that same still-present investigator
        """
    )
    func inspectingSurvivingInvestigatorRestoresFocusAfterInsertion() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        controller.selectZone(BoardFocusZone.investigators)
        let inspectedInvestigatorID = controller.projection.investigators[0].id
        #expect(controller.handle(.command(.inspect)))
        #expect(controller.inspectedID == BoardFocusID.investigator(inspectedInvestigatorID))

        // Insert a brand-new location alongside the two already present; the inspected
        // investigator's own identity is entirely unaffected.
        let thirdLocationID = BoardTestFixtures.locationID("000000000303")
        var locations = controller.projection.locations.map {
            ($0.id, Location.ordinary(BoardTestFixtures.ordinaryLocation(id: $0.id)))
        }
        locations.append(
            (thirdLocationID, .ordinary(BoardTestFixtures.ordinaryLocation(id: thirdLocationID)))
        )
        let investigator = BoardTestFixtures.investigator(id: inspectedInvestigatorID)
        let snapshot = BoardTestFixtures.snapshot(
            locations: locations,
            investigators: [inspectedInvestigatorID: investigator],
            playerOrder: [inspectedInvestigatorID],
            activeInvestigatorID: inspectedInvestigatorID,
            leadInvestigatorID: inspectedInvestigatorID
        )
        controller.applySnapshot(BoardProjectionBuilder.makeProjection(from: snapshot))

        let expectedFocus = BoardFocusID.investigator(inspectedInvestigatorID)
        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.inspectedID == nil)
        #expect(controller.coordinator.currentFocus == expectedFocus)
    }

    @Test("Focus on an unaffected node survives applySnapshot with reordered entities")
    func focusSurvivesReorderedEntities() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        controller.selectZone(BoardFocusZone.investigators)
        let focusBefore = controller.coordinator.currentFocus
        // Rebuild the identical projection (a no-op "reorder"): entity identities are
        // unchanged, so focus must remain exactly where it was.
        controller.applySnapshot(twoLocationProjection())
        #expect(controller.coordinator.currentFocus == focusBefore)
    }

    @Test(
        """
        reconcileOnAppear leaves an open inspector untouched when the reappearing view's \
        projection is unchanged from what the controller already holds
        """
    )
    func reconcileOnAppearNoOpWhenProjectionUnchanged() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        #expect(controller.handle(.command(.inspect)))
        #expect(controller.coordinator.isModalPresented)

        // A freshly-rebuilt but content-equal projection: exercises `Equatable`, not
        // identity, matching how a re-rendered `BoardView` would receive its `let
        // projection` parameter again unchanged.
        controller.reconcileOnAppear(with: twoLocationProjection())

        // Genuinely unchanged relative to what's held: the open inspector must survive a
        // stale-view reappearance, unlike a real `applySnapshot` replacement (see
        // `inspectorClosesAutomaticallyOnSnapshotReplacement` above).
        #expect(controller.coordinator.isModalPresented)
        #expect(controller.inspectedID != nil)
    }

    @Test(
        """
        reconcileOnAppear applies a missed replacement snapshot that arrived while the \
        view was off-screen, exactly as applySnapshot would
        """
    )
    func reconcileOnAppearAppliesMissedSnapshot() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        let firstLocationID = controller.projection.locations[0].id
        #expect(controller.coordinator.currentFocus == BoardFocusID.scenarioHeader)

        // A projection missing the previously-focused-adjacent location entirely,
        // standing in for an update the view's `.onChange` never observed while hidden.
        let replacement = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        controller.reconcileOnAppear(with: replacement)

        #expect(controller.projection == replacement)
        #expect(controller.coordinator.currentFocus != BoardFocusID.location(firstLocationID))
    }
}
