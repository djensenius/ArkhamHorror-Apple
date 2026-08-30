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

    @Test(
        """
        Presenting the inspector actually transitions currentFocus to its own node, and \
        dismissal actually transitions it back
        """
    )
    func inspectorPresentationActuallyTransitionsCurrentFocus() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        controller.selectZone(BoardFocusZone.locations)
        let locationFocus = controller.coordinator.currentFocus
        #expect(locationFocus != nil)
        #expect(controller.handle(.command(.inspect)))
        // A genuine transition (never the same node reused as its own modal entry, which
        // would leave `currentFocus` unchanged and silently fail to notify anything
        // observing it — for example `BoardView`'s `@FocusState` sync via `.onChange`).
        #expect(controller.coordinator.currentFocus == BoardFocusID.inspectorClose)
        #expect(controller.coordinator.currentFocus != locationFocus)
        #expect(controller.handle(.command(.secondaryAction)))
        #expect(controller.coordinator.currentFocus == locationFocus)
    }

    @Test("A repeated inspect/primaryAction while already open closes it, never stacking a modal")
    func repeatedInspectClosesRatherThanStackingModal() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        let focusBeforeInspect = controller.coordinator.currentFocus
        #expect(controller.handle(.command(.inspect)))
        #expect(controller.coordinator.isModalPresented)
        #expect(controller.coordinator.currentFocus == BoardFocusID.inspectorClose)
        // A second `.inspect`/`.primaryAction` (for example the inspector's own Close
        // control dispatching a tap as `.primaryAction`) must close the already-open
        // inspector — never attempt a second, nested `presentModal(entry:)` call, which
        // would otherwise require two dismissals to fully close and could strand
        // `isModalPresented == true` with no inspector content visible.
        #expect(controller.handle(.command(.inspect)))
        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.inspectedID == nil)
        #expect(controller.coordinator.currentFocus == focusBeforeInspect)
        // Proves the modal stack itself was never corrupted by the toggle: opening again
        // afterward still works exactly like the first time.
        #expect(controller.handle(.command(.inspect)))
        #expect(controller.coordinator.isModalPresented)
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

    @Test(
        """
        reservedBack (for example the tvOS Siri Remote Menu button) with an inspector open \
        dismisses it, reporting itself consumed, and restores the prior focus
        """
    )
    func reservedBackWithInspectorOpenDismissesItAndRestoresFocus() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        controller.selectZone(BoardFocusZone.investigators)
        let focusBeforeInspect = controller.coordinator.currentFocus
        #expect(controller.handle(.command(.inspect)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.inspectorClose)
        #expect(controller.handle(.reservedBack))
        #expect(!controller.coordinator.isModalPresented)
        #expect(controller.coordinator.currentFocus == focusBeforeInspect)
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

    // MARK: - Modal focus isolation

    @Test("cycleZone is a no-op while the inspector modal is presented")
    func cycleZoneNoOpWhileModalPresented() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        #expect(controller.handle(.command(.inspect)))
        #expect(!controller.handle(.command(.cycleZone(.next))))
        #expect(controller.coordinator.currentFocus == BoardFocusID.inspectorClose)
        #expect(controller.coordinator.isModalPresented)
    }

    @Test("jumpToActivePrompt is a no-op while the inspector modal is presented, even if pending")
    func jumpToActivePromptNoOpWhileModalPresented() {
        let snapshot = BoardTestFixtures.snapshot(questionCount: 1)
        let controller = BoardCommandController(
            projection: BoardProjectionBuilder.makeProjection(from: snapshot)
        )
        #expect(controller.handle(.command(.inspect)))
        #expect(!controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.inspectorClose)
    }

    @Test("selectZone is a no-op while the inspector modal is presented")
    func selectZoneNoOpWhileModalPresented() {
        let controller = BoardCommandController(projection: twoLocationProjection())
        #expect(controller.handle(.command(.inspect)))
        controller.selectZone(BoardFocusZone.locations)
        #expect(controller.coordinator.currentFocus == BoardFocusID.inspectorClose)
        #expect(controller.coordinator.isModalPresented)
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
