import Foundation
import Observation

/// The `@MainActor` orchestrator behind ``SemanticInputHarnessView``: owns a
/// ``FocusCoordinator`` over ``SemanticInputHarnessFixture``'s graph, an
/// optional injected ``ControllerInputCenter``, and the single
/// ``handle(_:)`` entry point every adapter (keyboard, Siri Remote,
/// controller, and the touch/pointer/vision action seam) feeds through.
///
/// Kept intentionally small and fixture-driven: this exists to prove the
/// input/focus/controller foundation end-to-end, not to host real gameplay
/// surfaces.
@MainActor
@Observable
final class SemanticInputHarnessModel {
    private(set) var coordinator: FocusCoordinator
    private(set) var controllerCenter: ControllerInputCenter?
    /// The most recently dispatched command, for on-screen/test verification.
    private(set) var lastCommand: SemanticCommand?
    /// Every focus target that has received `.primaryAction` at least once,
    /// for on-screen/test verification (for example, checking that pressing
    /// "Play" while a specific seat is focused acted on that seat, not some
    /// other one).
    private(set) var activatedTargets: Set<SemanticFocusID> = []

    @ObservationIgnored private let controllerDiscovery: (any ControllerDiscovering)?

    /// Constructing this model performs no side effects whatsoever — it
    /// neither creates nor starts a ``ControllerInputCenter`` — so it is
    /// always safe to evaluate (and, if necessary, discard) more than once,
    /// as SwiftUI's own `@State(initialValue:)` machinery may legitimately do
    /// across a view struct's repeated `init`/re-render cycle. Only an
    /// explicit ``start()`` call (from a stable lifecycle point such as
    /// `.task`) creates and starts the controller center.
    init(controllerDiscovery: (any ControllerDiscovering)? = nil) {
        coordinator = FocusCoordinator(
            graph: SemanticInputHarnessFixture.makeGraph(),
            initialFocus: SemanticInputHarnessFixture.boardSeatOne
        )
        self.controllerDiscovery = controllerDiscovery
    }

    /// Lazily creates (on first call only) and starts the injected
    /// controller center. Idempotent: calling this again while already
    /// started is a no-op that reuses the same center, and calling it again
    /// after ``stop()`` resumes dispatch on that same center rather than
    /// constructing a second one — so a view's `.task` re-running (for
    /// example after a transient disappear/reappear) can never install a
    /// second, competing set of button handlers on a shared real controller.
    func start() {
        guard let controllerDiscovery else { return }
        if let controllerCenter {
            controllerCenter.start()
            return
        }
        let center = ControllerInputCenter(discovery: controllerDiscovery) { [weak self] in
            self?.handle($0)
        }
        controllerCenter = center
        center.start()
    }

    /// The single dispatch entry point every input adapter feeds through.
    /// Returns whether this outcome was actually consumed: always `true` for
    /// a ``SemanticCommand`` (this closed vocabulary has no "let it fall
    /// through" concept) unless ``apply(_:)`` reports it did not actually act
    /// on the command (for example a command this fixture-driven harness
    /// deliberately leaves unimplemented), and `false` for
    /// ``SemanticDispatchOutcome/reservedBack`` when there is no modal to
    /// dismiss — so a caller (for example the keyboard adapter) can let
    /// Escape/Menu-style system behavior, or an unconsumed command's own
    /// platform-native meaning (for example Tab's Full Keyboard Access
    /// traversal), fall through to whatever other responder would otherwise
    /// handle it, instead of always swallowing it.
    @discardableResult
    func handle(_ outcome: SemanticDispatchOutcome) -> Bool {
        handle(focusID: nil, outcome)
    }

    /// Identical to ``handle(_:)``, but first syncs ``FocusCoordinator/currentFocus``
    /// to `focusID` (via ``FocusCoordinator/syncExternalFocus(_:)``) when
    /// non-`nil`. Lets a per-node action control (``SemanticActionControl``)
    /// report its own semantic identity at the moment of dispatch, so a
    /// direct tap/click/accessibility-activation on a target other than the
    /// coordinator's current notion of focus still acts on the node the user
    /// actually activated — even before any `@FocusState` round-trip back
    /// into the coordinator would otherwise have caught up.
    @discardableResult
    func handle(focusID: SemanticFocusID?, _ outcome: SemanticDispatchOutcome) -> Bool {
        coordinator.syncExternalFocus(focusID)
        switch outcome {
        case .reservedBack:
            guard coordinator.isModalPresented else { return false }
            coordinator.dismissModal()
            return true
        case let .command(command):
            lastCommand = command
            return apply(command)
        }
    }

    /// Applies `command` and reports whether this harness actually acted on
    /// it. Every case this fixture-driven harness implements returns `true`;
    /// any command it deliberately leaves unimplemented (the `default`
    /// branch) returns `false`, so callers never mistake "we don't do
    /// anything with this here" for "this was consumed" — most importantly
    /// so a native platform behavior riding the same input (for example Tab
    /// driving Full Keyboard Access traversal, which this harness does not
    /// implement any effect for) is never swallowed by a harness that has
    /// nothing to do with it.
    private func apply(_ command: SemanticCommand) -> Bool {
        switch command {
        case let .focusMove(direction):
            coordinator.move(direction)
            return true
        case .toggleMenuSurface:
            if coordinator.isModalPresented {
                coordinator.dismissModal()
            } else {
                coordinator.presentModal(entry: SemanticInputHarnessFixture.menuClose)
            }
            return true
        case .primaryAction:
            if let focused = coordinator.currentFocus {
                activatedTargets.insert(focused)
            }
            return true
        default:
            return false
        }
    }

    /// Tears down the injected controller center, if any. Call before
    /// releasing this model in a long-lived host (for example a preview or
    /// test that constructs many models in a loop).
    func stop() {
        controllerCenter?.stop()
    }
}
