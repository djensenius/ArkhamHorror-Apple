import SwiftUI

/// The reusable, read-only native Arkham Horror board: a fixture/snapshot-backed
/// presentation of a decoded ``PublicGameSnapshot`` (via ``BoardProjection``), adaptive
/// across compact iPhone, iPad, resizable macOS, tvOS, and visionOS.
///
/// Deliberately **not** `public`: this issue is a fixture-backed presentation slice with
/// no lifecycle/root integration. `ArkhamHorrorSharedTests`'s `@testable import` already
/// gives the internal fixture gallery/harness (and every test) full access; a future PR
/// that wires this into the app's root navigation can widen access then.
///
/// Each `BoardView` value owns its own ``BoardCommandController`` instance (created once,
/// in `onAppear`), so two simultaneously-visible `BoardView`s (for example two visionOS
/// windows, or a gallery listing more than one fixture) never share mutable focus or zoom
/// state.
struct BoardView: View {
    let projection: BoardProjection

    @State private var controller: BoardCommandController?
    @FocusState private var focusedID: SemanticFocusID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS) || os(visionOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    init(projection: BoardProjection) {
        self.projection = projection
    }

    var body: some View {
        Group {
            if let controller {
                boardBody(controller)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if controller == nil {
                let newController = BoardCommandController(projection: projection)
                controller = newController
                focusedID = newController.coordinator.currentFocus
            }
        }
        .onChange(of: projection) { _, newValue in
            controller?.applySnapshot(newValue)
        }
    }

    @ViewBuilder
    private func boardBody(_ controller: BoardCommandController) -> some View {
        ZStack {
            ArkhamTheme.backgroundGradient.ignoresSafeArea()
            content(controller)
                .disabled(controller.coordinator.isModalPresented)
                .accessibilityHidden(controller.coordinator.isModalPresented)
            if let inspectorContent = resolvedInspectorContent(controller) {
                BoardInspectorView(
                    content: inspectorContent,
                    focusBinding: $focusedID,
                    onOutcome: { controller.handle(focusID: $0, $1) }
                )
            }
        }
        .semanticKeyboardInput { controller.handle($0) }
        #if os(tvOS)
            .semanticSiriRemoteInput(
                canHandleBack: { controller.coordinator.isModalPresented },
                onOutcome: { controller.handle($0) }
            )
        #endif
            .onChange(of: controller.coordinator.currentFocus) { _, newValue in
                focusedID = newValue
            }
            .onChange(of: focusedID) { _, newValue in
                controller.coordinator.syncExternalFocus(newValue)
            }
            .animation(
                BoardAnimationPolicy.modalTransition(reduceMotion: reduceMotion),
                value: controller.coordinator.isModalPresented
            )
    }

    @ViewBuilder
    private func content(_ controller: BoardCommandController) -> some View {
        #if os(iOS) || os(visionOS)
            if BoardLayoutDecision.usesCompactLayout(horizontalSizeClass: horizontalSizeClass) {
                BoardCompactLayoutView(controller: controller, focusBinding: $focusedID)
            } else {
                BoardRegularLayoutView(controller: controller, focusBinding: $focusedID)
            }
        #else
            BoardRegularLayoutView(controller: controller, focusBinding: $focusedID)
        #endif
    }

    /// Resolves the entity content for the currently-inspected node, or `nil` when no
    /// inspector is presented. Extracted purely to avoid a multi-condition `if let` chain
    /// whose wrapped opening brace SwiftLint's `opening_brace` rule flags.
    private func resolvedInspectorContent(
        _ controller: BoardCommandController
    ) -> BoardInspectorContent? {
        guard controller.coordinator.isModalPresented, let inspectedID = controller.inspectedID
        else {
            return nil
        }
        return BoardInspectorContent.resolve(id: inspectedID, in: controller.projection)
    }
}

/// Pure Reduce-Motion transition policy: fully disabled (`nil`) under Reduce Motion,
/// otherwise the system default — extracted from ``BoardView/body`` so it is directly
/// unit-testable without instantiating any view.
enum BoardAnimationPolicy {
    static func modalTransition(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .default
    }
}

#if os(iOS) || os(visionOS)
    /// Pure compact/regular layout decision — extracted from ``BoardView/content(_:)`` so
    /// it is directly unit-testable without instantiating any view or environment.
    enum BoardLayoutDecision {
        static func usesCompactLayout(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
            horizontalSizeClass == .compact
        }
    }
#endif

/// The regular-width layout: every zone visible at once in a scrollable column, with a
/// zoom control cluster for touch/pointer platforms. Used for iPad regular width,
/// resizable macOS windows, tvOS (ten-foot, focus-first), and the visionOS window.
struct BoardRegularLayoutView: View {
    let controller: BoardCommandController
    let focusBinding: FocusState<SemanticFocusID?>.Binding

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 20) {
                header
                HStack(alignment: .top, spacing: 20) {
                    BoardActAgendaColumnView(
                        acts: controller.projection.acts,
                        agendas: controller.projection.agendas,
                        focusedID: controller.coordinator.currentFocus,
                        focusBinding: focusBinding,
                        onOutcome: { controller.handle(focusID: $0, $1) }
                    )
                    .frame(width: 220)
                    BoardLocationBoardView(
                        locations: controller.projection.locations,
                        layout: controller.layout,
                        zoomScale: controller.zoomScale,
                        focusedID: controller.coordinator.currentFocus,
                        focusBinding: focusBinding,
                        onOutcome: { controller.handle(focusID: $0, $1) }
                    )
                }
                BoardEnemyLocationsRowView(
                    enemyLocations: controller.projection.enemyLocations,
                    focusedID: controller.coordinator.currentFocus,
                    focusBinding: focusBinding,
                    onOutcome: { controller.handle(focusID: $0, $1) }
                )
                BoardInvestigatorRowView(
                    investigators: controller.projection.investigators,
                    otherInvestigatorCount: controller.projection.otherInvestigatorCount,
                    killedInvestigatorCount: controller.projection.killedInvestigatorCount,
                    focusedID: controller.coordinator.currentFocus,
                    focusBinding: focusBinding,
                    onOutcome: { controller.handle(focusID: $0, $1) }
                )
            }
            .padding(24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            BoardScenarioHeaderView(
                scenario: controller.projection.scenario,
                hasCampaignContext: controller.projection.hasCampaignContext,
                counters: controller.projection.counters,
                isFocused: controller.coordinator.currentFocus == BoardFocusID.scenarioHeader,
                focusBinding: focusBinding,
                onOutcome: { controller.handle(focusID: $0, $1) }
            )
            HStack(alignment: .top, spacing: 20) {
                BoardChaosBagView(
                    chaosBag: controller.projection.chaosBag,
                    isFocused: controller.coordinator.currentFocus == BoardFocusID.chaosBagSummary,
                    focusBinding: focusBinding,
                    onOutcome: { controller.handle(focusID: $0, $1) }
                )
                BoardZoomControlsView(controller: controller)
            }
        }
    }
}

/// A small on-screen zoom control cluster for touch/pointer platforms, dispatching the
/// exact same ``SemanticCommand/zoomIn``/``SemanticCommand/zoomOut``/
/// ``SemanticCommand/resetCamera`` commands the keyboard/controller/Siri Remote adapters
/// already do — never a bespoke pinch/drag gesture or virtual cursor.
struct BoardZoomControlsView: View {
    let controller: BoardCommandController

    var body: some View {
        HStack(spacing: 12) {
            Button {
                controller.handle(.command(.zoomOut))
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .accessibilityLabel(Text("Zoom out"))
            Button {
                controller.handle(.command(.resetCamera))
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .accessibilityLabel(Text("Reset view"))
            Button {
                controller.handle(.command(.zoomIn))
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .accessibilityLabel(Text("Zoom in"))
        }
        .buttonStyle(.bordered)
    }
}
