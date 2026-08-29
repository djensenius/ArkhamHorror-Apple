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
struct SemanticActionControl<Label: View>: View {
    let accessibilityLabel: Text
    let onOutcome: (SemanticDispatchOutcome) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            onOutcome(.command(.primaryAction))
        } label: {
            label()
        }
        .onLongPressGesture {
            onOutcome(.command(.secondaryAction))
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
