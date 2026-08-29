import SwiftUI

/// The shared touch/pointer/visionOS-focus "action seam": a standard SwiftUI
/// `Button` (never a custom hit-tested pointer or gaze target) whose tap
/// dispatches ``SemanticCommand/primaryAction`` and whose optional long press
/// dispatches ``SemanticCommand/secondaryAction`` — through the exact same
/// ``SemanticDispatchOutcome`` seam every other adapter uses.
///
/// Touch (iOS/iPadOS), pointer (macOS/iPadOS trackpad and mouse), and
/// visionOS look-and-pinch selection all already invoke a native `Button`'s
/// action identically; no platform-specific gesture code exists or is needed
/// here, and no virtual cursor position is read or stored anywhere in this
/// type.
///
/// A plain `Button` still recognizes its own tap on touch-up even after a
/// simultaneously-attached long-press gesture has already completed, which
/// would otherwise dispatch both ``SemanticCommand/secondaryAction`` and
/// ``SemanticCommand/primaryAction`` for the same single long-press
/// interaction. `suppressNextPrimaryAction` records that a long press just
/// completed so the following, spurious button-tap action is swallowed
/// exactly once — while keeping `Button` itself (rather than a bespoke
/// gesture recognizer) as the primary-action trigger, so VoiceOver, Switch
/// Control, and keyboard Full Keyboard Access activation (space/return) all
/// keep working exactly as they do for any other native button.
///
/// `suppressNextPrimaryAction` is only ever cleared by `Button`'s own action
/// firing, so a completed long press whose touch is then dragged away (or
/// whose view is replaced) before lift-off — leaving `Button`'s action
/// never called — would otherwise leave it stuck `true` forever,
/// incorrectly swallowing the *next*, entirely unrelated tap. `isLongPressing`
/// (backed by the same `LongPressGesture`'s own `updating` state, which
/// SwiftUI reports as `true` from the moment the press begins — well before
/// `minimumDuration` elapses and `onEnded` fires — not only once it
/// succeeds) clears the flag proactively at the start of every new press —
/// before that press's own `Button` action or this gesture's `onEnded` can
/// possibly fire — so a stale `true` from an abandoned interaction can
/// never survive past the very next touch-down. (A separate zero-distance
/// `DragGesture` was considered for this same "press began" signal, but
/// `DragGesture` is unavailable on tvOS; reusing `LongPressGesture`'s own
/// `updating` state keeps this control available on every platform target.)
public struct SemanticActionControl<Label: View>: View {
    public let accessibilityLabel: Text
    public let onOutcome: (SemanticDispatchOutcome) -> Void
    @ViewBuilder public let label: () -> Label

    @State private var suppressNextPrimaryAction = false
    @GestureState private var isLongPressing = false

    public init(
        accessibilityLabel: Text,
        onOutcome: @escaping (SemanticDispatchOutcome) -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.onOutcome = onOutcome
        self.label = label
    }

    public var body: some View {
        Button {
            if suppressNextPrimaryAction {
                suppressNextPrimaryAction = false
                return
            }
            onOutcome(.command(.primaryAction))
        } label: {
            label()
        }
        .simultaneousGesture(
            LongPressGesture()
                .updating($isLongPressing) { currentState, state, _ in
                    state = currentState
                }
                .onEnded { _ in
                    suppressNextPrimaryAction = true
                    onOutcome(.command(.secondaryAction))
                }
        )
        .onChange(of: isLongPressing) { wasPressing, nowPressing in
            if !wasPressing, nowPressing {
                suppressNextPrimaryAction = false
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
