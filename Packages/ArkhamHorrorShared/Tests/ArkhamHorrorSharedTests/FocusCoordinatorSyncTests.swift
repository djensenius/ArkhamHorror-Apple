@testable import ArkhamHorrorShared
import Observation
import Testing

/// Coverage for ``FocusCoordinator/syncExternalFocus(_:)`` (system/native
/// focus reconciliation) and for the ``FocusCoordinator/isModalPresented``
/// Observation-tracking regression. Split from ``FocusCoordinatorTests``
/// purely to keep ``FocusGraphTests.swift`` within the project's
/// `file_length` lint budget; both files share the same "small, explicit
/// graphs, no geometry" testing style.
@MainActor
@Suite("FocusCoordinator — external focus sync and Observation tracking")
struct FocusCoordinatorSyncTests {
    // MARK: - syncExternalFocus (system/native focus reconciliation)

    @Test("syncExternalFocus adopts a system-driven focus change to an existing node")
    func syncExternalFocusAdoptsExistingNode() {
        let graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z", neighbors: [.up: "b"]),
                FocusNode(id: "b", zone: "z"),
            ]
        )
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "a")
        coordinator.syncExternalFocus("b")
        #expect(coordinator.currentFocus == "b")
    }

    @Test("A directional move after syncExternalFocus starts from the newly synced node")
    func moveAfterSyncStartsFromSyncedNode() {
        let graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z"),
                FocusNode(id: "b", zone: "z", neighbors: [.up: "c"]),
                FocusNode(id: "c", zone: "z"),
            ]
        )
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "a")
        // Simulates a system/native focus change (Full Keyboard Access,
        // direct tap, tvOS focus engine) landing on "b" without ever calling
        // move(_:) — the coordinator's own notion of current focus was
        // stale ("a") until this sync.
        coordinator.syncExternalFocus("b")
        coordinator.move(.up)
        // Resolves via "b"'s own declared edge, not "a"'s (which has none),
        // proving the move started from the synced node, not the stale one.
        #expect(coordinator.currentFocus == "c")
    }

    @Test("syncExternalFocus ignores nil, unknown, and already-current targets (idempotent)")
    func syncExternalFocusIsASafeNoOpWhenNotApplicable() {
        let graph = FocusGraph(nodes: [FocusNode(id: "a", zone: "z")])
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "a")
        coordinator.syncExternalFocus(nil)
        #expect(coordinator.currentFocus == "a")
        coordinator.syncExternalFocus("unknown")
        #expect(coordinator.currentFocus == "a")
        coordinator.syncExternalFocus("a")
        #expect(coordinator.currentFocus == "a")
    }

    // MARK: - Observation regression: isModalPresented must invalidate on its own

    /// A small `@unchecked Sendable` counter: `withObservationTracking`'s
    /// `onChange` closure is itself `@Sendable`, so a plain captured local
    /// `var` cannot be mutated from inside it. This test only ever calls
    /// `increment()` synchronously on the main actor (from directly within
    /// this same test function, driven by `FocusCoordinator`'s own
    /// main-actor-isolated mutations above), so `@unchecked` is safe here.
    private final class ChangeCounter: @unchecked Sendable {
        private(set) var count = 0
        func increment() {
            count += 1
        }
    }

    @Test("isModalPresented is independently observable even when currentFocus does not change")
    func isModalPresentedIsObservableIndependentlyOfCurrentFocus() {
        let graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z"),
                // The modal's entry point is the *same* node already
                // focused, so presentModal(entry:)/dismissModal() below
                // never change `currentFocus` at all — the only true signal
                // available is `isModalPresented` itself.
            ]
        )
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "a")
        let counter = ChangeCounter()
        func observeOnce() {
            withObservationTracking {
                _ = coordinator.isModalPresented
            } onChange: {
                counter.increment()
            }
        }
        observeOnce()
        coordinator.presentModal(entry: "a")
        #expect(coordinator.currentFocus == "a")
        #expect(coordinator.isModalPresented)
        #expect(counter.count == 1)
        observeOnce()
        coordinator.dismissModal()
        #expect(!coordinator.isModalPresented)
        #expect(counter.count == 2)
    }
}
