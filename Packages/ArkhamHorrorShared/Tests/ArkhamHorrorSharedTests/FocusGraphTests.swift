@testable import ArkhamHorrorShared
import Testing

/// Coverage for ``FocusGraph``'s deterministic resolution and ``FocusCoordinator``'s
/// modal-return/removal-fallback/snapshot-restoration behavior layered on top of it.
/// Every scenario here is deliberately built from small, explicit graphs rather than
/// on-screen geometry, matching the graph's own "no geometry-only behavior" contract.
@MainActor
@Suite("FocusGraph and FocusCoordinator — deterministic focus")
struct FocusGraphTests {
    // MARK: - Deterministic ties / wrap

    @Test("An explicit declared edge always wins over wrap, even when wrap would also resolve")
    func explicitEdgeWinsOverWrap() {
        var graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z", neighbors: [.right: "c"]),
                FocusNode(id: "b", zone: "z"),
                FocusNode(id: "c", zone: "z"),
            ],
            wrapPolicy: .wrapWithinZone
        )
        // Insertion order is a, b, c; a naive wrap would send "a" right to "b", but the
        // explicit edge to "c" must still win.
        #expect(graph.neighbor(from: "a", direction: .right) == "c")
        graph.remove("c")
        // With "c" gone, "a"'s explicit edge is dangling and wrap takes over: the only
        // remaining zone member besides "a" is "b".
        #expect(graph.neighbor(from: "a", direction: .right) == "b")
    }

    @Test("wrapWithinZone resolves ties deterministically by insertion order, not dictionary order")
    func wrapResolvesByInsertionOrder() {
        let graph = FocusGraph(
            nodes: [
                FocusNode(id: "third", zone: "z"),
                FocusNode(id: "first", zone: "z"),
                FocusNode(id: "second", zone: "z"),
            ],
            wrapPolicy: .wrapWithinZone
        )
        // Declared order is third, first, second — wrap must follow that exact order,
        // not alphabetical or hash order.
        #expect(graph.neighbor(from: "third", direction: .right) == "first")
        #expect(graph.neighbor(from: "first", direction: .right) == "second")
        #expect(graph.neighbor(from: "second", direction: .right) == "third")
        #expect(graph.neighbor(from: "third", direction: .left) == "second")
    }

    @Test("A single-member zone never wraps to itself")
    func singleMemberZoneDoesNotWrap() {
        let graph = FocusGraph(
            nodes: [FocusNode(id: "only", zone: "z")], wrapPolicy: .wrapWithinZone
        )
        #expect(graph.neighbor(from: "only", direction: .right) == nil)
    }

    // MARK: - Sparse fallback policy (.noWrap)

    @Test("noWrap leaves focus unchanged for any direction with no explicit edge")
    func noWrapPolicyNeverMovesFocus() {
        let graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z", neighbors: [.right: "b"]),
                FocusNode(id: "b", zone: "z"),
            ], wrapPolicy: .noWrap
        )
        #expect(graph.neighbor(from: "a", direction: .right) == "b")
        #expect(graph.neighbor(from: "b", direction: .right) == nil)
        #expect(graph.neighbor(from: "a", direction: .up) == nil)
    }

    @Test("FocusCoordinator.move(_:) is a safe no-op when no neighbor resolves")
    func coordinatorMoveNoOpWhenNoNeighbor() {
        let graph = FocusGraph(nodes: [FocusNode(id: "only", zone: "z")], wrapPolicy: .noWrap)
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "only")
        coordinator.move(.up)
        #expect(coordinator.currentFocus == "only")
    }

    // MARK: - Removal fallback

    @Test("Removing the focused node with a declared removalFallback restores that target")
    func removalFallbackDeclaredTargetWins() {
        let graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z", removalFallback: "c"),
                FocusNode(id: "b", zone: "z"),
                FocusNode(id: "c", zone: "z"),
            ]
        )
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "a")
        coordinator.remove("a")
        #expect(coordinator.currentFocus == "c")
    }

    @Test("Removal falls back to the zone entry point when there is no declared fallback")
    func removalFallbackUsesZoneEntryPoint() {
        let graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z"),
                FocusNode(id: "b", zone: "z"),
            ], zoneEntryPoints: ["z": "b"]
        )
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "a")
        coordinator.remove("a")
        #expect(coordinator.currentFocus == "b")
    }

    @Test("Removal falls back to the first remaining node in declared order as a last resort")
    func removalFallbackUsesFirstRemainingNode() {
        let graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z"),
                FocusNode(id: "b", zone: "z"),
                FocusNode(id: "c", zone: "z"),
            ]
        )
        var mutableGraph = graph
        mutableGraph.remove("a")
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "a")
        coordinator.remove("a")
        // "a" was first; after removing it "b" is the first remaining node, matching
        // the plain graph-level removal above.
        #expect(coordinator.currentFocus == mutableGraph.order.first)
        #expect(coordinator.currentFocus == "b")
    }

    @Test("Removing a node that is not currently focused never moves focus")
    func removingUnfocusedNodeLeavesFocusUnchanged() {
        let graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z"),
                FocusNode(id: "b", zone: "z"),
            ]
        )
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "a")
        coordinator.remove("b")
        #expect(coordinator.currentFocus == "a")
    }

    // MARK: - Modal return target

    @Test("dismissModal restores the exact focus that was current before presentModal")
    func modalReturnsToPriorFocus() {
        let graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z"),
                FocusNode(id: "menu", zone: "m"),
            ]
        )
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "a")
        coordinator.presentModal(entry: "menu")
        #expect(coordinator.currentFocus == "menu")
        #expect(coordinator.isModalPresented)
        coordinator.dismissModal()
        #expect(coordinator.currentFocus == "a")
        #expect(!coordinator.isModalPresented)
    }

    @Test("Nested modals restore in strict LIFO order regardless of stack depth")
    func nestedModalsRestoreInLIFOOrder() {
        let graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z"),
                FocusNode(id: "menu1", zone: "m1"),
                FocusNode(id: "menu2", zone: "m2"),
            ]
        )
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "a")
        coordinator.presentModal(entry: "menu1")
        coordinator.presentModal(entry: "menu2")
        #expect(coordinator.currentFocus == "menu2")
        coordinator.dismissModal()
        #expect(coordinator.currentFocus == "menu1")
        #expect(coordinator.isModalPresented)
        coordinator.dismissModal()
        #expect(coordinator.currentFocus == "a")
        #expect(!coordinator.isModalPresented)
    }

    @Test("dismissModal with no modal presented is a safe no-op")
    func dismissModalNoOpWhenNothingPresented() {
        let graph = FocusGraph(nodes: [FocusNode(id: "a", zone: "z")])
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "a")
        coordinator.dismissModal()
        #expect(coordinator.currentFocus == "a")
    }

    @Test("Removing a modal's remembered return target falls back deterministically on dismiss")
    func modalReturnTargetRemovalFallsBackDeterministically() {
        let graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z"),
                FocusNode(id: "b", zone: "z"),
                FocusNode(id: "menu", zone: "m"),
            ]
        )
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "a")
        coordinator.presentModal(entry: "menu")
        coordinator.remove("a")
        #expect(coordinator.currentFocus == "menu")
        coordinator.dismissModal()
        // "a" (the remembered return target) is gone; its stack entry was cleared to
        // `nil` by `remove(_:)`, so dismissal resolves through the graph's generic,
        // deterministic fallback (the first remaining node in declared order) rather
        // than restoring the stale, removed identifier.
        #expect(coordinator.currentFocus == "b")
    }

    // MARK: - Insertion / removal / snapshot restoration

    @Test("Inserting a node while nothing is focused focuses it")
    func insertFocusesFirstNodeWhenNothingFocused() {
        let coordinator = FocusCoordinator(graph: FocusGraph())
        #expect(coordinator.currentFocus == nil)
        coordinator.insert(FocusNode(id: "a", zone: "z"))
        #expect(coordinator.currentFocus == "a")
    }

    @Test("Re-inserting an existing node preserves its original order position")
    func reinsertingExistingNodePreservesOrder() {
        var graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z"),
                FocusNode(id: "b", zone: "z"),
            ]
        )
        graph.insert(FocusNode(id: "a", zone: "z", neighbors: [.right: "b"]))
        #expect(graph.order == ["a", "b"])
        #expect(graph.neighbor(from: "a", direction: .right) == "b")
    }

    @Test("applySnapshot is idempotent: applying the same graph twice leaves focus unchanged")
    func applySnapshotIsIdempotent() {
        let graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z"),
                FocusNode(id: "b", zone: "z"),
            ]
        )
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "b")
        coordinator.applySnapshot(graph)
        #expect(coordinator.currentFocus == "b")
        coordinator.applySnapshot(graph)
        #expect(coordinator.currentFocus == "b")
    }

    @Test(
        "applySnapshot falls back deterministically when the focused node is absent from the graph"
    )
    func applySnapshotFallsBackWhenFocusedNodeIsRemoved() {
        let oldGraph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z", removalFallback: "b"),
                FocusNode(id: "b", zone: "z"),
            ]
        )
        let coordinator = FocusCoordinator(graph: oldGraph, initialFocus: "a")
        let newGraph = FocusGraph(nodes: [FocusNode(id: "b", zone: "z")])
        coordinator.applySnapshot(newGraph)
        #expect(coordinator.currentFocus == "b")
    }

    @Test("Repeated applySnapshot calls with an unchanged graph and preferred target are stable")
    func repeatedSnapshotsWithSamePreferredTargetAreStable() {
        let graph = FocusGraph(
            nodes: [
                FocusNode(id: "a", zone: "z"),
                FocusNode(id: "b", zone: "z"),
            ]
        )
        let coordinator = FocusCoordinator(graph: graph, initialFocus: "a")
        for _ in 0 ..< 5 {
            coordinator.applySnapshot(graph)
            #expect(coordinator.currentFocus == "a")
        }
    }

    // MARK: - Harness fixture smoke coverage

    @Test("The harness fixture's board zone wraps directionally and the menu zone is modal-only")
    func harnessFixtureWrapsAndIsolatesMenuZone() {
        let graph = SemanticInputHarnessFixture.makeGraph()
        // Seat 1 has no explicit .left/.up edge, so both wrap to the previous member in
        // declared insertion order (board seat 1, 2, 3, 4) — seat 4.
        #expect(
            graph.neighbor(from: SemanticInputHarnessFixture.boardSeatOne, direction: .left)
                == SemanticInputHarnessFixture.boardSeatFour
        )
        #expect(
            graph.neighbor(from: SemanticInputHarnessFixture.boardSeatOne, direction: .up)
                == SemanticInputHarnessFixture.boardSeatFour
        )
        // The explicit edge still wins over wrap in the same direction it is declared.
        #expect(
            graph.neighbor(from: SemanticInputHarnessFixture.boardSeatOne, direction: .down)
                == SemanticInputHarnessFixture.boardSeatThree
        )
        #expect(
            graph.zoneEntryPoints[SemanticInputHarnessFixture.menuZone]
                == SemanticInputHarnessFixture.menuClose
        )
    }
}
