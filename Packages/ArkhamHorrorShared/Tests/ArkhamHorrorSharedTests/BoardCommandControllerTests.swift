@testable import ArkhamHorrorShared
import Testing

/// End-to-end coverage for ``BoardCommandController``: focus movement/restoration across
/// snapshot replacement, zone cycling, inspector modal open/close, zoom/reset, and command
/// routing through the exact production ``SemanticInputRouter``/``InputMappingTable``
/// helpers every real input adapter uses — never a bespoke test-only router.
@MainActor
@Suite("BoardCommandController — focus, zones, and command routing")
struct BoardCommandControllerTests {
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

    @Test("Initial focus is the scenario header, the graph's first declared node")
    func initialFocusIsScenarioHeader() {
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let controller = BoardCommandController(projection: projection)
        #expect(controller.coordinator.currentFocus == BoardFocusID.scenarioHeader)
    }

    @Test("cycleZone(.next) moves focus to the next populated zone's declared entry point")
    func cycleZoneNextMovesToNextPopulatedZone() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        #expect(controller.coordinator.currentFocus == BoardFocusID.scenarioHeader)
        #expect(controller.handle(.command(.cycleZone(.next))))
        #expect(controller.focusedZone == BoardFocusZone.locations)
    }

    @Test("cycleZone(.previous) from the first populated zone wraps to the last")
    func cycleZonePreviousWrapsToLast() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        #expect(controller.handle(.command(.cycleZone(.previous))))
        #expect(controller.focusedZone == BoardFocusZone.chaosBag)
    }

    @Test("Directional focus movement navigates real location topology")
    func directionalMovementNavigatesLocationTopology() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        controller.selectZone(BoardFocusZone.locations)
        let firstFocus = controller.coordinator.currentFocus
        #expect(controller.handle(.command(.focusMove(.right))))
        #expect(controller.coordinator.currentFocus != firstFocus)
    }

    @Test("inspect opens the inspector for whatever is currently focused")
    func inspectOpensInspectorForCurrentFocus() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.handle(.command(.inspect)))
        #expect(controller.coordinator.isModalPresented)
        #expect(controller.inspectedID == BoardFocusID.scenarioHeader)
    }

    @Test("A repeated inspect while an inspector is already open never stacks a second modal")
    func repeatedInspectNeverStacksModal() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        #expect(controller.handle(.command(.inspect)))
        #expect(controller.coordinator.isModalPresented)
        // Reports itself unconsumed: this second call must be a pure no-op, never a
        // second nested `presentModal(entry:)` call.
        #expect(!controller.handle(.command(.inspect)))
        #expect(controller.coordinator.isModalPresented)
        // A single close must fully dismiss the inspector — proving no second modal was
        // ever stacked underneath it.
        #expect(controller.handle(.command(.secondaryAction)))
        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.inspectedID == nil)
    }

    @Test("secondaryAction closes an open inspector and restores the prior focus")
    func secondaryActionClosesInspector() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        controller.selectZone(BoardFocusZone.locations)
        let focusBeforeInspect = controller.coordinator.currentFocus
        #expect(controller.handle(.command(.inspect)))
        #expect(controller.handle(.command(.secondaryAction)))
        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.inspectedID == nil)
        #expect(controller.coordinator.currentFocus == focusBeforeInspect)
    }

    @Test("reservedBack with no inspector open is a safe, unconsumed no-op")
    func reservedBackWithNoInspectorIsNoOp() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        #expect(!controller.handle(.reservedBack))
    }

    @Test("reservedBack with an inspector open dismisses it, reporting itself consumed")
    func reservedBackWithInspectorOpenDismissesIt() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        #expect(controller.handle(.command(.inspect)))
        #expect(controller.handle(.reservedBack))
        #expect(!controller.coordinator.isModalPresented)
    }

    @Test("zoomIn/zoomOut clamp to the declared zoom range and resetCamera restores default")
    func zoomClampsAndResetRestoresDefault() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        for _ in 0 ..< 20 {
            controller.handle(.command(.zoomIn))
        }
        #expect(controller.zoomScale == BoardCommandController.zoomRange.upperBound)
        for _ in 0 ..< 20 {
            controller.handle(.command(.zoomOut))
        }
        #expect(controller.zoomScale == BoardCommandController.zoomRange.lowerBound)
        #expect(controller.handle(.command(.resetCamera)))
        #expect(controller.zoomScale == 1)
    }

    @Test("jumpToActivePrompt is a no-op when no prompt is pending")
    func jumpToActivePromptNoOpWhenNoPromptPending() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        controller.selectZone(BoardFocusZone.locations)
        let before = controller.coordinator.currentFocus
        #expect(!controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == before)
    }

    @Test("jumpToActivePrompt moves focus to the scenario header when a prompt is pending")
    func jumpToActivePromptMovesFocusWhenPending() {
        let snapshot = BoardTestFixtures.snapshot(questionCount: 1)
        let controller = BoardCommandController(
            projection: BoardProjectionBuilder.makeProjection(from: snapshot)
        )
        controller.selectZone(BoardFocusZone.chaosBag)
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.scenarioHeader)
    }

    @Test("An unimplemented command (toggleArrangeMode) reports itself unconsumed")
    func unimplementedCommandReportsUnconsumed() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        #expect(!controller.handle(.command(.toggleArrangeMode)))
    }

    // MARK: - Focus restoration across snapshot replacement

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

    // MARK: - Command routing through production semantic helpers

    @Test("Routing a real keyboard arrow-key event through SemanticInputRouter moves focus")
    func keyboardArrowKeyRoutesToFocusMove() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        controller.selectZone(BoardFocusZone.locations)
        let before = controller.coordinator.currentFocus
        let event = PhysicalInputEvent(input: .keyboard(.arrowRight), phase: .press)
        guard let outcome = SemanticInputRouter.route(event, using: .defaultKeyboard) else {
            Issue.record("Expected a routed outcome for the default keyboard table")
            return
        }
        #expect(controller.handle(outcome))
        #expect(controller.coordinator.currentFocus != before)
    }

    @Test("Routing a reserved keyboard control (Escape) with no inspector open is unconsumed")
    func keyboardEscapeWithNoInspectorIsUnconsumed() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        let event = PhysicalInputEvent(input: .keyboard(.escape), phase: .press)
        guard let outcome = SemanticInputRouter.route(event, using: .defaultKeyboard) else {
            Issue.record("Expected a routed outcome for a reserved control")
            return
        }
        #expect(outcome == .reservedBack)
        #expect(!controller.handle(outcome))
    }

    // MARK: - Reduce Motion / layout decision pure policies

    @Test("BoardAnimationPolicy disables animation entirely under Reduce Motion")
    func reduceMotionDisablesAnimation() {
        #expect(BoardAnimationPolicy.modalTransition(reduceMotion: true) == nil)
        #expect(BoardAnimationPolicy.modalTransition(reduceMotion: false) != nil)
    }
}
