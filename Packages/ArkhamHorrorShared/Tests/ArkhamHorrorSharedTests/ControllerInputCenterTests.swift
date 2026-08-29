@testable import ArkhamHorrorShared
import Testing

/// A dummy reference type used purely to mint distinct, stable ``ControllerID``
/// values in tests, independent of any fake controller's own identity.
private final class ControllerIdentityToken {}

/// A deterministic, injectable ``ControllerDiscovering`` fake: connect/disconnect
/// are driven explicitly by tests rather than by real hardware or NotificationCenter.
@MainActor
private final class FakeControllerDiscovery: ControllerDiscovering {
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

    func simulateDisconnect(_ id: ControllerID) {
        onDisconnect?(id)
    }
}

/// A deterministic, injectable ``ControllerInputSource`` fake: button events are
/// fired explicitly by tests via ``fire(_:_:)`` rather than by a real `GCExtendedGamepad`.
@MainActor
private final class FakeControllerInputSource: ControllerInputSource {
    // Retained for the fake's whole lifetime: `ObjectIdentifier` records an object's
    // address, so a purely temporary token would be deallocated immediately after use,
    // letting ARC reuse its address for the *next* token and silently collide two
    // supposedly distinct controllers onto the same `ControllerID`.
    private let identityToken = ControllerIdentityToken()
    let id: ControllerID
    let snapshot: ControllerSnapshot
    var onButtonEvent: ((ControllerControl, InputPhase) -> Void)?

    init(glyphFamily: ControllerGlyphFamily = .xbox, vendorName: String? = "Fake Controller") {
        let id = ControllerID(objectID: ObjectIdentifier(identityToken))
        self.id = id
        snapshot = ControllerSnapshot(
            id: id, profile: .extendedGamepad, glyphFamily: glyphFamily, vendorName: vendorName
        )
    }

    func fire(_ control: ControllerControl, _ phase: InputPhase) {
        onButtonEvent?(control, phase)
    }
}

/// Coverage for ``ControllerInputCenter``'s connect/disconnect/reconnect lifecycle,
/// stale/disconnected-event suppression, duplicate press/repeat/release routing,
/// teardown, and glyph-family tracking — all driven through the injected
/// ``ControllerDiscovering``/``ControllerInputSource`` test seam.
@MainActor
@Suite("ControllerInputCenter — connect/disconnect/dispatch")
struct ControllerInputCenterTests {
    private func makeCenter(
        discovery: FakeControllerDiscovery, dispatched: @escaping (SemanticDispatchOutcome) -> Void
    ) -> ControllerInputCenter {
        ControllerInputCenter(discovery: discovery, dispatch: dispatched)
    }

    @Test("start() begins discovery exactly once and is idempotent")
    func startIsIdempotent() {
        let discovery = FakeControllerDiscovery()
        let center = makeCenter(discovery: discovery) { _ in }
        center.start()
        center.start()
        #expect(discovery.startCallCount == 1)
    }

    @Test("Connecting a controller records its snapshot and adopts its glyph family")
    func connectRecordsSnapshotAndGlyphFamily() {
        let discovery = FakeControllerDiscovery()
        let center = makeCenter(discovery: discovery) { _ in }
        center.start()
        let source = FakeControllerInputSource(glyphFamily: .playStation)
        discovery.simulateConnect(source)
        #expect(center.connectedControllers == [source.snapshot])
        #expect(center.activeGlyphFamily == .playStation)
    }

    @Test("A bound button press dispatches the correctly routed command for the connected glyph")
    func buttonPressDispatchesRoutedCommand() {
        let discovery = FakeControllerDiscovery()
        var dispatched: [SemanticDispatchOutcome] = []
        let center = makeCenter(discovery: discovery) { dispatched.append($0) }
        center.start()
        let source = FakeControllerInputSource(glyphFamily: .xbox)
        discovery.simulateConnect(source)
        source.fire(.dpadUp, .press)
        #expect(dispatched == [.command(.focusMove(.up))])
    }

    @Test("Duplicate press/repeat/release events follow the router's own repeatable-command policy")
    func duplicatePressRepeatReleaseFollowsRouterPolicy() {
        let discovery = FakeControllerDiscovery()
        var dispatched: [SemanticDispatchOutcome] = []
        let center = makeCenter(discovery: discovery) { dispatched.append($0) }
        center.start()
        let source = FakeControllerInputSource()
        discovery.simulateConnect(source)
        // dpadUp -> .focusMove(.up) is repeatable: press and repeat both dispatch.
        source.fire(.dpadUp, .press)
        source.fire(.dpadUp, .repeatPress)
        source.fire(.dpadUp, .release)
        #expect(dispatched == [.command(.focusMove(.up)), .command(.focusMove(.up))])
        dispatched.removeAll()
        // buttonA -> .primaryAction is not repeatable: only the press dispatches.
        source.fire(.buttonA, .press)
        source.fire(.buttonA, .repeatPress)
        source.fire(.buttonA, .release)
        #expect(dispatched == [.command(.primaryAction)])
    }

    @Test("Disconnecting a controller removes it and resets glyph family when none remain")
    func disconnectRemovesControllerAndResetsGlyphFamily() {
        let discovery = FakeControllerDiscovery()
        let center = makeCenter(discovery: discovery) { _ in }
        center.start()
        let source = FakeControllerInputSource(glyphFamily: .mfi)
        discovery.simulateConnect(source)
        discovery.simulateDisconnect(source.id)
        #expect(center.connectedControllers.isEmpty)
        #expect(center.activeGlyphFamily == .unknown)
    }

    @Test("A button event fired after disconnect (a stale, in-flight callback) is suppressed")
    func staleEventAfterDisconnectIsSuppressed() {
        let discovery = FakeControllerDiscovery()
        var dispatched: [SemanticDispatchOutcome] = []
        let center = makeCenter(discovery: discovery) { dispatched.append($0) }
        center.start()
        let source = FakeControllerInputSource()
        discovery.simulateConnect(source)
        // Capture the installed handler before disconnect, simulating an event that was
        // already "in flight" the instant the disconnect notification is processed.
        let staleHandler = source.onButtonEvent
        discovery.simulateDisconnect(source.id)
        staleHandler?(.dpadUp, .press)
        #expect(dispatched.isEmpty)
    }

    @Test("Reconnecting after a disconnect resumes dispatch and updates glyph family")
    func reconnectResumesDispatch() {
        let discovery = FakeControllerDiscovery()
        var dispatched: [SemanticDispatchOutcome] = []
        let center = makeCenter(discovery: discovery) { dispatched.append($0) }
        center.start()
        let first = FakeControllerInputSource(glyphFamily: .xbox)
        discovery.simulateConnect(first)
        discovery.simulateDisconnect(first.id)
        let second = FakeControllerInputSource(glyphFamily: .playStation)
        discovery.simulateConnect(second)
        second.fire(.buttonA, .press)
        #expect(center.activeGlyphFamily == .playStation)
        #expect(dispatched == [.command(.primaryAction)])
    }

    @Test("Disconnecting one of two connected controllers falls back to the other's glyph family")
    func disconnectingOneOfTwoFallsBackToRemainingGlyphFamily() {
        let discovery = FakeControllerDiscovery()
        let center = makeCenter(discovery: discovery) { _ in }
        center.start()
        let first = FakeControllerInputSource(glyphFamily: .xbox)
        let second = FakeControllerInputSource(glyphFamily: .mfi)
        discovery.simulateConnect(first)
        discovery.simulateConnect(second)
        #expect(center.activeGlyphFamily == .mfi)
        discovery.simulateDisconnect(second.id)
        #expect(center.activeGlyphFamily == .xbox)
        #expect(center.connectedControllers == [first.snapshot])
    }

    @Test("stop() tears down discovery, clears state, is idempotent, and suppresses further events")
    func stopTearsDownAndSuppressesFurtherEvents() {
        let discovery = FakeControllerDiscovery()
        var dispatched: [SemanticDispatchOutcome] = []
        let center = makeCenter(discovery: discovery) { dispatched.append($0) }
        center.start()
        let source = FakeControllerInputSource()
        discovery.simulateConnect(source)
        let handler = source.onButtonEvent
        center.stop()
        center.stop()
        #expect(discovery.stopCallCount == 1)
        #expect(center.connectedControllers.isEmpty)
        #expect(center.activeGlyphFamily == .unknown)
        handler?(.dpadUp, .press)
        #expect(dispatched.isEmpty)
    }
}
