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
public struct SemanticActionControl<Label: View>: View {
    public let accessibilityLabel: Text
    public let onOutcome: (SemanticDispatchOutcome) -> Void
    @ViewBuilder public let label: () -> Label

    @State private var suppressNextPrimaryAction = false

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
            LongPressGesture().onEnded { _ in
                suppressNextPrimaryAction = true
                onOutcome(.command(.secondaryAction))
            }
        )
        .accessibilityLabel(accessibilityLabel)
    }
}
