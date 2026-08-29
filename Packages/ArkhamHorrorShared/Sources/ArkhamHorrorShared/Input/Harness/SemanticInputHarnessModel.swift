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

    init(controllerDiscovery: (any ControllerDiscovering)? = nil) {
        coordinator = FocusCoordinator(
            graph: SemanticInputHarnessFixture.makeGraph(),
            initialFocus: SemanticInputHarnessFixture.boardSeatOne
        )
        if let controllerDiscovery {
            let center = ControllerInputCenter(discovery: controllerDiscovery) { [weak self] in
                self?.handle($0)
            }
            controllerCenter = center
            center.start()
        }
    }

    /// The single dispatch entry point every input adapter feeds through.
    /// Returns whether this outcome was actually consumed: always `true` for
    /// a ``SemanticCommand`` (this closed vocabulary has no "let it fall
    /// through" concept), but `false` for ``SemanticDispatchOutcome/reservedBack``
    /// when there is no modal to dismiss — so a caller (for example the
    /// keyboard adapter) can let Escape/Menu-style system behavior fall
    /// through to whatever other responder would otherwise handle it,
    /// instead of always swallowing it.
    @discardableResult
    func handle(_ outcome: SemanticDispatchOutcome) -> Bool {
        switch outcome {
        case .reservedBack:
            guard coordinator.isModalPresented else { return false }
            coordinator.dismissModal()
            return true
        case let .command(command):
            lastCommand = command
            apply(command)
            return true
        }
    }

    private func apply(_ command: SemanticCommand) {
        switch command {
        case let .focusMove(direction):
            coordinator.move(direction)
        case .toggleMenuSurface:
            if coordinator.isModalPresented {
                coordinator.dismissModal()
            } else {
                coordinator.presentModal(entry: SemanticInputHarnessFixture.menuClose)
            }
        case .primaryAction:
            if let focused = coordinator.currentFocus {
                activatedTargets.insert(focused)
            }
        default:
            break
        }
    }

    /// Tears down the injected controller center, if any. Call before
    /// releasing this model in a long-lived host (for example a preview or
    /// test that constructs many models in a loop).
    func stop() {
        controllerCenter?.stop()
    }
}
