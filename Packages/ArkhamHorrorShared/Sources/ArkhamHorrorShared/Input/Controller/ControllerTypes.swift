import Foundation

/// A stable identity for one connected controller instance, independent of
/// connection order — but only for the lifetime of that single connection.
/// The production adapter derives this from `ObjectIdentifier(GCController)`,
/// and GameController vends a *new* `GCController` instance each time a
/// physical device reconnects, so this identity intentionally does not (and
/// is not meant to) persist across a disconnect/reconnect of the same
/// physical device: callers observe that as an ordinary new connect event,
/// with a new ``ControllerID`` to match, requiring no special-casing beyond
/// what any other connect event already needs.
public struct ControllerID: Hashable, Sendable {
    private let objectID: ObjectIdentifier

    public init(objectID: ObjectIdentifier) {
        self.objectID = objectID
    }
}

/// The glyph family used to render button prompts for a connected
/// controller. Distinct from ``ControllerControl`` (which is already
/// brand-independent): this exists purely so presentation code can choose the
/// right glyph set, never to change which semantic command a control
/// produces.
public enum ControllerGlyphFamily: Hashable, Sendable {
    case xbox
    case playStation
    case mfi
    case unknown
}

/// Which input profile a connected controller exposes.
public enum ControllerProfileKind: Hashable, Sendable {
    /// The controller exposes `GCExtendedGamepad` (or equivalent): every
    /// ``ControllerControl`` case is meaningful.
    case extendedGamepad
    /// The controller is connected but exposes no profile this layer
    /// understands; it never calls ``ControllerInputSource/onButtonEvent``.
    case unsupported
}

/// An immutable, `Equatable` description of one connected controller, safe to
/// store in `@Observable` state and to compare in tests without touching the
/// live controller.
public struct ControllerSnapshot: Sendable, Equatable {
    public let id: ControllerID
    public let profile: ControllerProfileKind
    public let glyphFamily: ControllerGlyphFamily
    public let vendorName: String?

    public init(
        id: ControllerID, profile: ControllerProfileKind, glyphFamily: ControllerGlyphFamily,
        vendorName: String?
    ) {
        self.id = id
        self.profile = profile
        self.glyphFamily = glyphFamily
        self.vendorName = vendorName
    }
}

/// The injected seam over one connected controller's button-level input, so
/// production code (backed by `GCExtendedGamepad`) and deterministic tests
/// (backed by a fake) share one shape. `@MainActor`-isolated: every
/// conformance is expected to be a reference type uniquely identifying one
/// physical controller, and ``onButtonEvent`` is only ever installed,
/// invoked, or torn down on the main actor.
@MainActor
public protocol ControllerInputSource: AnyObject {
    var id: ControllerID { get }
    var snapshot: ControllerSnapshot { get }
    /// Installed by ``ControllerInputCenter``. A conformance must stop
    /// invoking this the moment its controller disconnects, and must never
    /// invoke it again afterward even if the underlying hardware briefly
    /// re-delivers a queued event.
    var onButtonEvent: ((ControllerControl, InputPhase) -> Void)? { get set }
}

/// Test/production seam for controller connect/disconnect discovery, injected
/// into ``ControllerInputCenter`` so tests can simulate hardware
/// deterministically without touching the real GameController framework.
@MainActor
public protocol ControllerDiscovering: AnyObject {
    /// Begins observing connect/disconnect, reporting every controller
    /// already connected at call time as an immediate `onConnect`. Calling
    /// `start` again before `stop` replaces the previous callbacks.
    func start(
        onConnect: @escaping (any ControllerInputSource) -> Void,
        onDisconnect: @escaping (ControllerID) -> Void
    )
    /// Stops observing and releases every retained callback/observer. Safe to
    /// call more than once.
    func stop()
}
