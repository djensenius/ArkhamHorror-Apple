@testable import ArkhamHorrorShared
import Testing

/// A dummy reference type used purely to mint distinct, stable ``ControllerID``
/// values in tests, independent of any fake controller's own identity.
private final class HarnessControllerIdentityToken {}

/// A minimal, injectable ``ControllerDiscovering``/``ControllerInputSource`` pair
/// scoped to this file, mirroring ``ControllerInputCenterTests``'s fakes but kept
/// separate (private) so each test file's fakes stay simple and self-contained.
@MainActor
private final class HarnessFakeControllerDiscovery: ControllerDiscovering {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private var onConnect: ((any ControllerInputSource) -> Void)?
    private var onDisconnect: ((ControllerID) -> Void)?

    func start(
        onConnect: @escaping (any ControllerInputSource) -> Void,
        onDisconnect: @escaping (ControllerID) -> Void
    ) {
        startCallCount += 1
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
    }

    func stop() {
        stopCallCount += 1
        onConnect = nil
        onDisconnect = nil
    }

    func simulateConnect(_ source: any ControllerInputSource) {
        onConnect?(source)
    }
}

@MainActor
private final class HarnessFakeControllerInputSource: ControllerInputSource {
    // See the identical comment in `ControllerInputCenterTests` for why this token
    // must be retained rather than used only as a temporary.
    private let identityToken = HarnessControllerIdentityToken()
    let id: ControllerID
    let snapshot: ControllerSnapshot
    var onButtonEvent: ((ControllerControl, InputPhase) -> Void)?
    var handlerOwner: ObjectIdentifier?

    init(glyphFamily: ControllerGlyphFamily = .xbox) {
        let id = ControllerID(objectID: ObjectIdentifier(identityToken))
        self.id = id
        snapshot = ControllerSnapshot(
            id: id, profile: .extendedGamepad, glyphFamily: glyphFamily, vendorName: nil
        )
    }

    func fire(_ control: ControllerControl, _ phase: InputPhase) {
        onButtonEvent?(control, phase)
    }
}

/// End-to-end coverage for ``SemanticInputHarnessModel`` driving
/// ``SemanticInputHarnessFixture``'s graph through the same single ``handle(_:)``
/// seam every platform adapter feeds through, including an injected fake
/// controller — proving the input/focus/controller foundation actually composes,
/// not just each layer in isolation.
@MainActor
@Suite("SemanticInputHarnessModel — fixture-driven end-to-end")
struct SemanticInputHarnessTests {
    @Test("Initial focus is the fixture's first declared board seat")
    func initialFocusIsFirstBoardSeat() {
        let model = SemanticInputHarnessModel()
        #expect(model.coordinator.currentFocus == SemanticInputHarnessFixture.boardSeatOne)
    }

    @Test("focusMove wraps within the board zone using the fixture's declared/wrap-resolved edges")
    func focusMoveWrapsWithinBoardZone() {
        let model = SemanticInputHarnessModel()
        model.handle(.command(.focusMove(.right)))
        #expect(model.coordinator.currentFocus == SemanticInputHarnessFixture.boardSeatTwo)
        // Seat 1 has no explicit .left edge; wrapping resolves to the last declared
        // board seat rather than leaving focus unmoved.
        model.handle(.command(.focusMove(.left)))
        model.handle(.command(.focusMove(.left)))
        #expect(model.coordinator.currentFocus == SemanticInputHarnessFixture.boardSeatFour)
    }

    @Test(
        "toggleMenuSurface presents the modal, and reservedBack dismisses it back to the prior seat"
    )
    func toggleMenuSurfacePresentsModalAndReservedBackDismisses() {
        let model = SemanticInputHarnessModel()
        model.handle(.command(.focusMove(.right)))
        #expect(model.coordinator.currentFocus == SemanticInputHarnessFixture.boardSeatTwo)
        model.handle(.command(.toggleMenuSurface))
        #expect(model.coordinator.currentFocus == SemanticInputHarnessFixture.menuClose)
        #expect(model.coordinator.isModalPresented)
        // Returns `true`: a modal was actually dismissed, so a caller like the
        // keyboard adapter should report the key as consumed.
        #expect(model.handle(.reservedBack))
        #expect(model.coordinator.currentFocus == SemanticInputHarnessFixture.boardSeatTwo)
        #expect(!model.coordinator.isModalPresented)
    }

    @Test(
        "reservedBack with no modal presented is a safe no-op, and reports itself as unconsumed"
    )
    func reservedBackWithNoModalIsNoOp() {
        let model = SemanticInputHarnessModel()
        // Returns `false`: nothing was dismissed, so a caller like the keyboard
        // adapter can let Escape fall through to another responder instead of
        // always swallowing it.
        #expect(!model.handle(.reservedBack))
        #expect(model.coordinator.currentFocus == SemanticInputHarnessFixture.boardSeatOne)
    }

    @Test("primaryAction records exactly the currently focused seat as activated")
    func primaryActionRecordsCurrentlyFocusedSeat() {
        let model = SemanticInputHarnessModel()
        model.handle(.command(.focusMove(.right)))
        model.handle(.command(.primaryAction))
        #expect(model.activatedTargets == [SemanticInputHarnessFixture.boardSeatTwo])
        #expect(model.lastCommand == .primaryAction)
        model.handle(.command(.focusMove(.down)))
        model.handle(.command(.primaryAction))
        #expect(
            model.activatedTargets == [
                SemanticInputHarnessFixture.boardSeatTwo, SemanticInputHarnessFixture.boardSeatFour,
            ]
        )
    }

    @Test("An injected fake controller drives the same seam as every other adapter")
    func injectedControllerDrivesSameSeam() {
        let discovery = HarnessFakeControllerDiscovery()
        let model = SemanticInputHarnessModel(controllerDiscovery: discovery)
        model.start()
        let source = HarnessFakeControllerInputSource(glyphFamily: .playStation)
        discovery.simulateConnect(source)
        #expect(model.controllerCenter?.activeGlyphFamily == .playStation)
        source.fire(.dpadRight, .press)
        #expect(model.coordinator.currentFocus == SemanticInputHarnessFixture.boardSeatTwo)
        source.fire(.buttonA, .press)
        #expect(model.activatedTargets == [SemanticInputHarnessFixture.boardSeatTwo])
    }

    @Test("stop() tears down the injected controller center and clears its connected controllers")
    func stopTearsDownInjectedControllerCenter() {
        let discovery = HarnessFakeControllerDiscovery()
        let model = SemanticInputHarnessModel(controllerDiscovery: discovery)
        model.start()
        let source = HarnessFakeControllerInputSource()
        discovery.simulateConnect(source)
        #expect(model.controllerCenter?.connectedControllers.isEmpty == false)
        model.stop()
        #expect(model.controllerCenter?.connectedControllers.isEmpty == true)
    }

    // MARK: - HIGH: deferred start() lifecycle (no side effects from init)

    @Test("Constructing a model with an injected discovery never starts it on its own")
    func constructingModelNeverStartsDiscoveryOnItsOwn() {
        let discovery = HarnessFakeControllerDiscovery()
        // Mirrors what SwiftUI's own `@State(initialValue:)` machinery may
        // legitimately do: construct-and-discard more than once across a
        // view struct's repeated init/re-render cycle.
        _ = SemanticInputHarnessModel(controllerDiscovery: discovery)
        _ = SemanticInputHarnessModel(controllerDiscovery: discovery)
        #expect(discovery.startCallCount == 0)
    }

    @Test("start() begins discovery exactly once, even when called more than once")
    func startBeginsDiscoveryExactlyOnceEvenWhenCalledRepeatedly() {
        let discovery = HarnessFakeControllerDiscovery()
        let model = SemanticInputHarnessModel(controllerDiscovery: discovery)
        model.start()
        model.start()
        model.start()
        #expect(discovery.startCallCount == 1)
    }

    @Test("start() reuses the same controller center across repeated calls, not a second one")
    func startReusesSameControllerCenterAcrossRepeatedCalls() {
        let discovery = HarnessFakeControllerDiscovery()
        let model = SemanticInputHarnessModel(controllerDiscovery: discovery)
        model.start()
        let firstCenter = model.controllerCenter
        model.start()
        #expect(model.controllerCenter === firstCenter)
    }

    @Test("stop() then start() again resumes dispatch on the same center, not a new one")
    func stopThenStartAgainResumesDispatchOnSameCenter() {
        let discovery = HarnessFakeControllerDiscovery()
        let model = SemanticInputHarnessModel(controllerDiscovery: discovery)
        model.start()
        let firstCenter = model.controllerCenter
        let source = HarnessFakeControllerInputSource()
        discovery.simulateConnect(source)
        source.fire(.dpadRight, .press)
        #expect(model.coordinator.currentFocus == SemanticInputHarnessFixture.boardSeatTwo)
        model.stop()
        model.start()
        #expect(model.controllerCenter === firstCenter)
        #expect(discovery.startCallCount == 2)
        let secondSource = HarnessFakeControllerInputSource()
        discovery.simulateConnect(secondSource)
        secondSource.fire(.dpadRight, .press)
        // Already at seat two (no explicit .right edge there) from the
        // earlier move; moving right again wrap-resolves to seat three,
        // proving dispatch resumed correctly on the very same center.
        #expect(model.coordinator.currentFocus == SemanticInputHarnessFixture.boardSeatThree)
    }

    @Test("A model with no injected discovery is safe to start() and stop() repeatedly")
    func modelWithNoInjectedDiscoveryIsSafeToStartAndStopRepeatedly() {
        let model = SemanticInputHarnessModel(controllerDiscovery: nil)
        model.start()
        model.start()
        model.stop()
        model.stop()
        #expect(model.controllerCenter == nil)
    }

    // MARK: - MEDIUM: bidirectional focus sync and per-control focus identity

    @Test("handle(focusID:_:) syncs the coordinator's focus before resolving the outcome")
    func handleWithFocusIDSyncsCoordinatorFocusFirst() {
        let model = SemanticInputHarnessModel()
        // Simulates a direct tap/click/accessibility-activation of a target
        // other than the coordinator's current notion of focus (seat one):
        // the action must apply to the tapped seat, not the stale one.
        let consumed = model.handle(
            focusID: SemanticInputHarnessFixture.boardSeatThree, .command(.primaryAction)
        )
        #expect(consumed)
        #expect(model.activatedTargets == [SemanticInputHarnessFixture.boardSeatThree])
        #expect(model.coordinator.currentFocus == SemanticInputHarnessFixture.boardSeatThree)
    }

    @Test("A directional move after a focusID-carrying tap starts from the newly-tapped node")
    func moveAfterFocusIDTapStartsFromTappedNode() {
        let model = SemanticInputHarnessModel()
        model.handle(focusID: SemanticInputHarnessFixture.boardSeatThree, .command(.primaryAction))
        model.handle(.command(.focusMove(.right)))
        #expect(model.coordinator.currentFocus == SemanticInputHarnessFixture.boardSeatFour)
    }

    // MARK: - Secondary: unimplemented commands report themselves as unconsumed

    @Test("A command this harness does not implement any effect for reports itself unconsumed")
    func unimplementedCommandReportsUnconsumed() {
        let model = SemanticInputHarnessModel()
        // .cyclePlayer(.next) (what Tab is bound to in the default keyboard
        // table) has no `case` in the harness's `apply(_:)` — it must report
        // `false` so a caller (the keyboard adapter) never swallows a Tab
        // press that Full Keyboard Access traversal still needs to see.
        #expect(!model.handle(.command(.cyclePlayer(.next))))
        // lastCommand is still recorded for on-screen/test verification,
        // even though the harness took no other action for it.
        #expect(model.lastCommand == .cyclePlayer(.next))
    }
}
