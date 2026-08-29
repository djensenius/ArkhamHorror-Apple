import SwiftUI

/// A fixture-driven SwiftUI gallery that can be operated end-to-end with a
/// hardware keyboard, a Siri Remote (tvOS), touch/pointer/visionOS focus, and
/// an injected (or, by default, real) game controller — entirely through
/// ``SemanticCommand``s, with deterministic focus restoration and no virtual
/// cursor.
///
/// `public` (like `RootView`) so it is constructible from every platform
/// target; not wired into any target's default navigation, since this issue
/// is foundation-only and intentionally does not add gameplay or board UI.
public struct SemanticInputHarnessView: View {
    @State private var model: SemanticInputHarnessModel
    @FocusState private var focusedID: SemanticFocusID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {
        #if canImport(GameController)
            let discovery = GameControllerDiscovery()
            self.init(model: SemanticInputHarnessModel(controllerDiscovery: discovery))
        #else
            self.init(model: SemanticInputHarnessModel(controllerDiscovery: nil))
        #endif
    }

    /// Not `public`: ``SemanticInputHarnessModel`` and ``ControllerDiscovering``
    /// are internal implementation types. Tests within this module use this
    /// to inject a fake controller discovery deterministically.
    init(model: SemanticInputHarnessModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(spacing: 24) {
            boardGrid
            Button("Menu") { model.handle(.command(.toggleMenuSurface)) }
                .accessibilityLabel(Text("Toggle menu"))
            if let lastCommand = model.lastCommand {
                Text("Last command: \(String(describing: lastCommand))")
                    .font(.caption)
                    .accessibilityLabel(Text("Last command \(String(describing: lastCommand))"))
            }
        }
        .padding()
        .overlay {
            if model.coordinator.isModalPresented {
                menuOverlay
            }
        }
        .semanticKeyboardInput { model.handle($0) }
        #if os(tvOS)
            .semanticSiriRemoteInput(
                canHandleBack: { model.coordinator.isModalPresented },
                onOutcome: { model.handle($0) }
            )
        #endif
            .onAppear { focusedID = model.coordinator.currentFocus }
            .task { model.start() }
            .onDisappear { model.stop() }
            .onChange(of: model.coordinator.currentFocus) { _, newValue in
                focusedID = newValue
            }
            .onChange(of: focusedID) { _, newValue in
                // The reverse direction of the sync immediately above:
                // whenever the platform's own native focus (Full Keyboard
                // Access Tab-traversal, direct touch/pointer/VoiceOver/
                // Switch Control activation, or the tvOS focus engine's own
                // geometry-driven movement) lands on a target other than
                // this coordinator's current notion of focus, push that
                // change back in. Both directions are equality-guarded
                // (here implicitly, since `syncExternalFocus` itself is a
                // no-op when `newValue` already equals `currentFocus`, and
                // the sibling direction above only assigns `focusedID` when
                // `currentFocus` actually changes), so this cannot become a
                // ping-pong feedback loop.
                model.coordinator.syncExternalFocus(newValue)
            }
            .animation(reduceMotion ? nil : .default, value: model.coordinator.isModalPresented)
    }

    private var boardGrid: some View {
        Grid {
            GridRow {
                boardSeat(SemanticInputHarnessFixture.boardSeatOne, label: "Seat 1")
                boardSeat(SemanticInputHarnessFixture.boardSeatTwo, label: "Seat 2")
            }
            GridRow {
                boardSeat(SemanticInputHarnessFixture.boardSeatThree, label: "Seat 3")
                boardSeat(SemanticInputHarnessFixture.boardSeatFour, label: "Seat 4")
            }
        }
    }

    private func boardSeat(_ id: SemanticFocusID, label: String) -> some View {
        SemanticActionControl(
            accessibilityLabel: Text(label),
            semanticFocusID: id,
            onOutcome: { focusID, outcome in model.handle(focusID: focusID, outcome) },
            label: {
                Text(label)
                    .frame(width: 96, height: 64)
                    .background(
                        model.activatedTargets.contains(id)
                            ? Color.accentColor : Color.gray.opacity(0.3)
                    )
            }
        )
        .focused($focusedID, equals: id)
    }

    private var menuOverlay: some View {
        VStack(spacing: 16) {
            Text("Menu")
            SemanticActionControl(
                accessibilityLabel: Text("Close menu"),
                semanticFocusID: SemanticInputHarnessFixture.menuClose,
                onOutcome: { focusID, outcome in model.handle(focusID: focusID, outcome) },
                label: { Text("Close") }
            )
            .focused($focusedID, equals: SemanticInputHarnessFixture.menuClose)
        }
        .padding()
        .background(.regularMaterial)
    }
}

#Preview("Semantic input harness") {
    SemanticInputHarnessView()
}
