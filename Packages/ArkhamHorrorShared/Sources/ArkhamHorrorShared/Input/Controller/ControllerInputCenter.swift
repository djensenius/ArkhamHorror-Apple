import Foundation
import Observation

/// The `@MainActor` owner of every connected controller's discovery, button
/// routing, and glyph-family state.
///
/// Ownership is one-directional: this center owns ``ControllerDiscovering``
/// and each connected ``ControllerInputSource`` strongly; every closure it
/// hands back to those seams captures `self` only weakly, so neither a
/// production `GameControllerDiscovery` nor a test fake can keep this center
/// alive past its own natural lifetime, and this center can never be kept
/// alive by a controller it no longer tracks.
///
/// Stale-event suppression: a button event is only ever dispatched while its
/// source's ``ControllerID`` is still present as a key in the internal
/// `sources` dictionary — checked at dispatch time (in
/// ``handleButtonEvent(from:control:phase:glyphFamily:)``), not merely at
/// handler-install time — so an event that was already in flight the
/// instant a disconnect is processed can never reach ``dispatch``.
@MainActor
@Observable
public final class ControllerInputCenter {
    public private(set) var connectedControllers: [ControllerSnapshot] = []
    public private(set) var activeGlyphFamily: ControllerGlyphFamily = .unknown

    @ObservationIgnored private var sources: [ControllerID: any ControllerInputSource] = [:]
    @ObservationIgnored private let discovery: any ControllerDiscovering
    @ObservationIgnored private let mappingTable: (ControllerGlyphFamily) -> InputMappingTable
    @ObservationIgnored private let dispatch: (SemanticDispatchOutcome) -> Void
    @ObservationIgnored private var isStarted = false

    public init(
        discovery: any ControllerDiscovering,
        mappingTable: @escaping (ControllerGlyphFamily) -> InputMappingTable = InputMappingTable
            .defaultTable(for:),
        dispatch: @escaping (SemanticDispatchOutcome) -> Void
    ) {
        self.discovery = discovery
        self.mappingTable = mappingTable
        self.dispatch = dispatch
    }

    isolated deinit {
        // A safety net for callers that never explicitly invoke `stop()`:
        // without it, a started center deallocated mid-session would leave
        // its `discovery`'s observers/handlers (e.g. `GameControllerDiscovery`'s
        // `NotificationCenter` tokens and button handlers) registered
        // indefinitely. `isolated deinit` (SE-0371) runs this synchronously
        // on the main actor, so it can call the same `@MainActor`-isolated
        // `stop()` used everywhere else, with no isolation assumption.
        stop()
    }

    /// Begins observing controller connect/disconnect. Safe to call more than
    /// once; only the first call (until ``stop()``) has any effect.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        discovery.start(
            onConnect: { [weak self] source in self?.handleConnect(source) },
            onDisconnect: { [weak self] id in self?.handleDisconnect(id) }
        )
    }

    /// Stops observing, detaches every tracked source's ``ControllerInputSource/onButtonEvent``,
    /// and clears all connected-controller state. Safe to call more than
    /// once, and safe to call from `deinit`-adjacent teardown code paths
    /// (this method itself performs no asynchronous work).
    public func stop() {
        guard isStarted else { return }
        isStarted = false
        discovery.stop()
        for (_, source) in sources {
            clearOwnedHandler(for: source)
        }
        sources.removeAll()
        connectedControllers.removeAll()
        activeGlyphFamily = .unknown
    }

    /// Nils `source.onButtonEvent`/`handlerOwner` only if `self` is still the
    /// recorded ``ControllerInputSource/handlerOwner`` — see that property's
    /// documentation. A no-op when some other (necessarily newer, since a
    /// source can only ever be re-owned by installing a fresh handler)
    /// center has since taken ownership of `source`.
    private func clearOwnedHandler(for source: any ControllerInputSource) {
        guard source.handlerOwner == ObjectIdentifier(self) else { return }
        source.onButtonEvent = nil
        source.handlerOwner = nil
    }

    private func handleConnect(_ source: any ControllerInputSource) {
        let id = source.id
        let glyphFamily = source.snapshot.glyphFamily
        sources[id] = source
        connectedControllers.removeAll { $0.id == id }
        connectedControllers.append(source.snapshot)
        activeGlyphFamily = glyphFamily
        source.handlerOwner = ObjectIdentifier(self)
        // Captures `id`/`glyphFamily` (value types), never `source` itself,
        // so this closure cannot form a retain cycle with the source it is
        // installed on: only `sources[id]` keeps the source alive, and only
        // `self`'s own lifetime (captured weakly) keeps this center
        // reachable. The mapping table is looked up fresh at dispatch time
        // (not captured here) so a caller whose `mappingTable` closure
        // reflects live remap state sees those remaps take effect
        // immediately, without requiring a disconnect/reconnect.
        source.onButtonEvent = { [weak self] control, phase in
            self?.handleButtonEvent(
                from: id, control: control, phase: phase, glyphFamily: glyphFamily
            )
        }
    }

    private func handleDisconnect(_ id: ControllerID) {
        if let source = sources[id] {
            clearOwnedHandler(for: source)
        }
        sources[id] = nil
        connectedControllers.removeAll { $0.id == id }
        activeGlyphFamily = connectedControllers.last?.glyphFamily ?? .unknown
    }

    private func handleButtonEvent(
        from id: ControllerID, control: ControllerControl, phase: InputPhase,
        glyphFamily: ControllerGlyphFamily
    ) {
        // Suppresses any event from a source this center no longer tracks —
        // including one captured by a closure from before a disconnect was
        // processed. See the type-level documentation above.
        guard sources[id] != nil else { return }
        // Looked up fresh on every event (never captured once at connect
        // time) so a `mappingTable` closure backed by live, mutable remap
        // state reflects a remap immediately, without requiring the
        // controller to disconnect and reconnect.
        let table = mappingTable(glyphFamily)
        guard
            let outcome = SemanticInputRouter.route(
                PhysicalInputEvent(input: .controller(control), phase: phase), using: table
            )
        else { return }
        dispatch(outcome)
    }
}
