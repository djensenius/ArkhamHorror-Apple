import Foundation
import Observation

/// The `@MainActor` owner of one live ``FocusGraph`` and the single currently
/// focused node, with deterministic modal-return, removal-fallback, and
/// snapshot-restoration behavior layered on top of the graph's pure
/// resolution functions.
///
/// This type owns no platform input code: adapters (keyboard, controller,
/// Siri Remote, pointer/touch/vision action seams) call ``move(_:)`` or read
/// ``currentFocus``; they never reach into ``graph`` directly.
@MainActor
@Observable
final class FocusCoordinator {
    private(set) var graph: FocusGraph
    private(set) var currentFocus: SemanticFocusID?

    /// Modal presentations in LIFO order; each entry is the focus to restore
    /// when that modal is dismissed (``dismissModal()``). Supports nested
    /// modals: dismissing the innermost one restores exactly the focus that
    /// was current immediately before it was presented, regardless of how
    /// many modals are stacked.
    ///
    /// Each remembered target also captures its zone/``FocusNode/removalFallback``
    /// at present-time, so that if the target is later removed from the
    /// graph, ``dismissModal()`` still resolves through the *same*
    /// declared-fallback → zone-entry-point → `order.first` policy that
    /// ``remove(_:)`` itself uses — rather than losing that context and
    /// falling straight to `order.first`.
    @ObservationIgnored private var modalReturnStack: [ModalReturnTarget?] = []

    /// One modal's remembered return target, along with the fallback
    /// information needed to resolve it deterministically if it no longer
    /// exists in the graph by the time its modal is dismissed.
    private struct ModalReturnTarget {
        let id: SemanticFocusID
        let zone: SemanticFocusZone?
        let declaredFallback: SemanticFocusID?
    }

    init(graph: FocusGraph, initialFocus: SemanticFocusID? = nil) {
        self.graph = graph
        currentFocus = initialFocus.flatMap { graph.contains($0) ? $0 : nil } ?? graph.order.first
    }

    /// Moves focus one step, if an explicit (or wrap-resolved) neighbor
    /// exists. A direction with no resolvable neighbor leaves focus unchanged
    /// — this never falls back to any geometry-based guess.
    func move(_ direction: FocusDirection) {
        guard let currentFocus, let next = graph.neighbor(from: currentFocus, direction: direction)
        else {
            return
        }
        self.currentFocus = next
    }

    /// Presents a modal, remembering the current focus as this modal's
    /// return target and moving focus to `entry` (falling back to the
    /// graph's first node if `entry` does not exist).
    func presentModal(entry: SemanticFocusID) {
        modalReturnStack.append(
            currentFocus.map { id in
                let node = graph.node(for: id)
                return ModalReturnTarget(
                    id: id, zone: node?.zone, declaredFallback: node?.removalFallback
                )
            }
        )
        currentFocus = graph.contains(entry) ? entry : graph.order.first
    }

    /// Dismisses the innermost modal, restoring its remembered return target
    /// (or the deterministic fallback, if that target no longer exists). A
    /// call with no modal presented is a safe no-op.
    func dismissModal() {
        guard let returnTarget = modalReturnStack.popLast() else { return }
        currentFocus = graph.restoreFocus(
            preferred: returnTarget?.id,
            previousZone: returnTarget?.zone,
            declaredFallback: returnTarget?.declaredFallback
        )
    }

    /// Whether a modal is currently presented (at least one entry remains on
    /// the return stack).
    var isModalPresented: Bool {
        !modalReturnStack.isEmpty
    }

    /// Inserts `node`. If nothing was focused yet, focus moves to it.
    func insert(_ node: FocusNode) {
        graph.insert(node)
        if currentFocus == nil {
            currentFocus = node.id
        }
    }

    /// Removes `id`. If `id` was the current focus, focus moves to the
    /// deterministic fallback derived from its own declared zone/fallback.
    /// Any remembered modal-return target naming `id` already captured that
    /// same zone/fallback information when its modal was presented (see
    /// ``ModalReturnTarget``), so a later ``dismissModal()`` still resolves
    /// deterministically even though `id` itself is now gone.
    func remove(_ id: SemanticFocusID) {
        let removedNode = graph.node(for: id)
        graph.remove(id)
        guard currentFocus == id else { return }
        currentFocus = graph.fallbackTarget(
            previousZone: removedNode?.zone, declaredFallback: removedNode?.removalFallback
        )
    }

    /// Replaces the entire graph (for example after a game-state update
    /// rebuilds every node), restoring focus deterministically: unchanged if
    /// still present in the new graph, else the fallback derived from the
    /// *previous* graph's zone/removal-fallback for the previously focused
    /// node. Applying the same snapshot twice in a row is idempotent.
    func applySnapshot(_ newGraph: FocusGraph) {
        let previousFocus = currentFocus
        let previousNode = previousFocus.flatMap { graph.node(for: $0) }
        graph = newGraph
        currentFocus = graph.restoreFocus(
            preferred: previousFocus,
            previousZone: previousNode?.zone,
            declaredFallback: previousNode?.removalFallback
        )
    }
}
