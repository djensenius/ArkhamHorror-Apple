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
            .semanticSiriRemoteInput { model.handle($0) }
        #endif
            .onAppear { focusedID = model.coordinator.currentFocus }
            .onChange(of: model.coordinator.currentFocus) { _, newValue in
                focusedID = newValue
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
            onOutcome: { model.handle($0) },
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
                onOutcome: { model.handle($0) },
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
