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
    private var onConnect: ((any ControllerInputSource) -> Void)?
    private var onDisconnect: ((ControllerID) -> Void)?

    func start(
        onConnect: @escaping (any ControllerInputSource) -> Void,
        onDisconnect: @escaping (ControllerID) -> Void
    ) {
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
    }

    func stop() {
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
        let source = HarnessFakeControllerInputSource()
        discovery.simulateConnect(source)
        #expect(model.controllerCenter?.connectedControllers.isEmpty == false)
        model.stop()
        #expect(model.controllerCenter?.connectedControllers.isEmpty == true)
    }
}
