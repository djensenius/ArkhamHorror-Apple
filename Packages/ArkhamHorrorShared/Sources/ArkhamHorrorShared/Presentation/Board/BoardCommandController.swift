import CoreGraphics
import Observation

/// The `@MainActor` owner of one board's live focus graph, local zoom presentation state,
/// and inspector selection — one instance per ``BoardView`` instance, so multiple
/// simultaneous board windows/instances (for example two visionOS windows, or a gallery
/// showing more than one fixture) never share mutable focus or zoom state.
///
/// Every mutation here is local presentation-only state or a pure re-derivation from the
/// current ``BoardProjection``; nothing here ever mutates backend topology or sends a
/// request. Commands are dispatched through the exact same ``SemanticCommand``/
/// ``FocusCoordinator`` seam the semantic input foundation already defines — this type
/// adds no new command vocabulary.
@MainActor
@Observable
final class BoardCommandController {
    private(set) var projection: BoardProjection
    private(set) var layout: BoardLayout
    private(set) var coordinator: FocusCoordinator
    /// Local zoom scale, clamped to ``zoomRange``. Never mutates backend topology; purely
    /// this presentation instance's own camera-equivalent state.
    private(set) var zoomScale: CGFloat = 1
    /// The entity currently shown in the focused inspector, or `nil` when no inspector is
    /// presented. Mirrors (but is distinct from) ``FocusCoordinator/isModalPresented``,
    /// which this type always keeps in lockstep with a non-`nil` value here.
    private(set) var inspectedID: SemanticFocusID?
    /// The most recently dispatched command, for on-screen/test verification.
    private(set) var lastCommand: SemanticCommand?

    static let zoomRange: ClosedRange<CGFloat> = 0.5 ... 3
    private static let zoomStep: CGFloat = 0.25

    init(projection: BoardProjection) {
        self.projection = projection
        let layout = BoardLayoutBuilder.makeLayout(
            locations: projection.locations,
            preferredRootID: Self.activeLocationID(in: projection)
        )
        self.layout = layout
        let graph = BoardFocusGraphBuilder.makeGraph(projection: projection, layout: layout)
        coordinator = FocusCoordinator(graph: graph, initialFocus: graph.order.first)
    }

    private static func activeLocationID(in projection: BoardProjection) -> LocationID? {
        projection.investigators.first(where: \.isActiveInvestigator)?.currentLocationID
    }

    /// Replaces the current projection with a freshly-decoded one (for example after a
    /// WebSocket `GameUpdate`). Any open inspector is closed first — returning focus to
    /// its underlying entity's position, itself then resolved through the new graph — so
    /// a replacement snapshot can never leave a dangling inspector open over an entity
    /// that may no longer exist. Zoom/pan presentation state is deliberately left
    /// untouched: a snapshot replacement is not a user-initiated "reset view".
    func applySnapshot(_ newProjection: BoardProjection) {
        if coordinator.isModalPresented {
            coordinator.dismissModal()
            inspectedID = nil
        }
        projection = newProjection
        layout = BoardLayoutBuilder.makeLayout(
            locations: newProjection.locations,
            preferredRootID: Self.activeLocationID(in: newProjection)
        )
        let newGraph = BoardFocusGraphBuilder.makeGraph(projection: newProjection, layout: layout)
        coordinator.applySnapshot(newGraph)
    }

    /// Reconciles this already-existing controller against the projection its owning
    /// ``BoardView`` was just handed on re-appearance. `.onChange(of: projection)` only
    /// fires while a view is part of the rendered tree, so a replacement snapshot that
    /// arrived while the view was off-screen (for example behind an inactive tab) could
    /// otherwise be missed entirely. Applies ``applySnapshot(_:)`` only when the
    /// projection genuinely changed, so an unchanged reappearance never spuriously
    /// dismisses an already-open inspector or perturbs zoom/pan state.
    func reconcileOnAppear(with latestProjection: BoardProjection) {
        guard projection != latestProjection else { return }
        applySnapshot(latestProjection)
    }

    /// The single dispatch entry point every input adapter feeds through, matching
    /// ``SemanticInputHarnessModel``'s own seam.
    @discardableResult
    func handle(_ outcome: SemanticDispatchOutcome) -> Bool {
        handle(focusID: nil, outcome)
    }

    @discardableResult
    func handle(focusID: SemanticFocusID?, _ outcome: SemanticDispatchOutcome) -> Bool {
        coordinator.syncExternalFocus(focusID)
        switch outcome {
        case .reservedBack:
            guard coordinator.isModalPresented else { return false }
            coordinator.dismissModal()
            inspectedID = nil
            return true
        case let .command(command):
            lastCommand = command
            return apply(command)
        }
    }

    private func apply(_ command: SemanticCommand) -> Bool {
        switch command {
        case let .focusMove(direction):
            coordinator.move(direction)
            return true
        case .primaryAction, .inspect:
            // While the inspector is already presented, its only interactive content is
            // the Close control itself (see `BoardInspectorView`): treat activating it
            // (a tap, Enter, or controller A-button primaryAction) as closing, exactly
            // like `.secondaryAction`, rather than re-attempting `openInspector()` (which
            // would otherwise just no-op against its own already-presented guard).
            return coordinator.isModalPresented ? closeInspector() : openInspector()
        case .secondaryAction:
            return closeInspector()
        case let .cycleZone(direction):
            return cycleZone(direction)
        case .zoomIn:
            setZoom(zoomScale + Self.zoomStep)
            return true
        case .zoomOut:
            setZoom(zoomScale - Self.zoomStep)
            return true
        case .resetCamera:
            zoomScale = 1
            return true
        case .jumpToActivePrompt:
            return jumpToActivePrompt()
        default:
            return false
        }
    }

    /// Presents the inspector for whatever is currently focused, recording it in
    /// ``inspectedID`` for content resolution and transitioning
    /// ``FocusCoordinator/currentFocus`` to the inspector's own permanent
    /// ``BoardFocusID/inspectorClose`` node (see ``FocusCoordinator/presentModal(entry:)``)
    /// — never reusing the same node that was already focused, which would otherwise
    /// leave `currentFocus` unchanged and silently fail to notify a bound `@FocusState`
    /// via SwiftUI's `.onChange`, stranding platform focus on the now-`disabled`/
    /// `accessibilityHidden` board underneath the modal. Dismissal (`closeInspector()`)
    /// still restores focus to exactly this entity afterward, since `presentModal(entry:)`
    /// itself remembers the pre-modal focus as the return target.
    ///
    /// A no-op (reported unconsumed) when an inspector is already presented: without this
    /// guard, a repeated `.inspect`/`.primaryAction` would stack a second modal via
    /// `presentModal(entry:)`, and a single subsequent close/back would then only pop the
    /// innermost one — leaving `isModalPresented == true` with no inspector content
    /// visible, and the board stuck disabled/`accessibilityHidden` behind it.
    private func openInspector() -> Bool {
        guard !coordinator.isModalPresented, let focused = coordinator.currentFocus else {
            return false
        }
        inspectedID = focused
        coordinator.presentModal(entry: BoardFocusID.inspectorClose)
        return true
    }

    private func closeInspector() -> Bool {
        guard coordinator.isModalPresented else { return false }
        coordinator.dismissModal()
        inspectedID = nil
        return true
    }

    /// Moves focus to the next/previous zone's declared entry point, skipping any zone
    /// with no navigable node (see
    /// ``BoardFocusGraphBuilder/nonEmptyZonesInCycleOrder(projection:)``).
    ///
    /// A no-op (reported unconsumed) while the inspector modal is presented: the modal
    /// has exactly one focusable control (its own Close button), and moving focus onto an
    /// underlying board zone's node would break modal focus isolation — that node sits
    /// behind the board content this same state already marks `disabled`/
    /// `accessibilityHidden`.
    private func cycleZone(_ direction: CycleDirection) -> Bool {
        guard !coordinator.isModalPresented else { return false }
        let zones = BoardFocusGraphBuilder.nonEmptyZonesInCycleOrder(projection: projection)
        guard !zones.isEmpty else { return false }
        let current = focusedZone ?? zones[0]
        let currentIndex = zones.firstIndex(of: current) ?? 0
        let step = direction == .next ? 1 : -1
        let nextIndex = (currentIndex + step + zones.count) % zones.count
        guard let entry = coordinator.graph.zoneEntryPoints[zones[nextIndex]] else { return false }
        coordinator.syncExternalFocus(entry)
        return true
    }

    /// Jumps directly to the scenario header, which surfaces
    /// `BoardCounters.pendingPromptCount` — the closest read-only equivalent this
    /// contract slice supports to "whatever currently holds an active prompt", since the
    /// actual `question` payload stays a broad, out-of-scope map. A no-op (reported as
    /// unconsumed) when no prompt is pending, or while the inspector modal is presented
    /// (see ``cycleZone(_:)``'s identical modal-isolation rationale).
    private func jumpToActivePrompt() -> Bool {
        guard !coordinator.isModalPresented, projection.counters.pendingPromptCount > 0 else {
            return false
        }
        coordinator.syncExternalFocus(BoardFocusID.scenarioHeader)
        return true
    }

    private func setZoom(_ value: CGFloat) {
        zoomScale = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    /// The zone containing ``FocusCoordinator/currentFocus``, or `nil` if nothing is
    /// currently focused.
    var focusedZone: SemanticFocusZone? {
        coordinator.currentFocus.flatMap { coordinator.graph.node(for: $0)?.zone }
    }

    /// Moves focus directly to `zone`'s declared entry point — for a native
    /// platform-driven selection (for example a compact-width zone switcher's segmented
    /// control), not a ``SemanticCommand``. A safe no-op if `zone` currently has no
    /// navigable node, or if the inspector modal is presented: the board content this
    /// selection would target is already `disabled`/`accessibilityHidden` behind the
    /// modal, and even a defensive guard here (rather than relying solely on that
    /// `disabled` state) keeps a future refactor or a direct programmatic call from ever
    /// breaking modal focus isolation.
    func selectZone(_ zone: SemanticFocusZone) {
        guard !coordinator.isModalPresented, let entry = coordinator.graph.zoneEntryPoints[zone]
        else {
            return
        }
        coordinator.syncExternalFocus(entry)
    }
}
