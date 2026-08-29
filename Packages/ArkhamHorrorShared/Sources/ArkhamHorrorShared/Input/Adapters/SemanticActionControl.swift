import SwiftUI

/// A small, pure state machine governing whether `Button`'s own tap action
/// should actually dispatch ``SemanticCommand/primaryAction`` — independent
/// of any SwiftUI view/gesture machinery, so its full lifecycle is directly
/// unit-testable.
///
/// A plain `Button` still recognizes its own tap on touch-up even after a
/// simultaneously-attached long-press gesture has already completed, which
/// would otherwise dispatch both ``SemanticCommand/secondaryAction`` and
/// ``SemanticCommand/primaryAction`` for the same single long-press
/// interaction. This state machine exists to suppress exactly that one,
/// spurious follow-on tap — while guaranteeing suppression can never survive
/// to swallow a later, entirely unrelated activation (for example, if the
/// long press's own touch is instead dragged away and lifted outside the
/// control's bounds, so `Button`'s action never fires at all to consume the
/// flag itself).
struct ActionSuppressionState: Equatable {
    private var isSuppressed = false

    /// Call at the rising edge of a new touch-based press (before this
    /// press's own gesture recognition or `Button` action can possibly
    /// run), clearing anything left behind by an earlier, already-resolved
    /// interaction.
    mutating func pressBegan() {
        isSuppressed = false
    }

    /// Call when `LongPressGesture` recognizes a completed long press.
    mutating func longPressSucceeded() {
        isSuppressed = true
    }

    /// Call when `Button`'s own action fires, from *any* modality — touch,
    /// pointer, VoiceOver, Switch Control, or keyboard Full Keyboard Access.
    /// Returns whether the primary action should actually be dispatched:
    /// `false` exactly once, immediately after a long press this same
    /// touch-up's own `Button` tap would otherwise double-fire for; `true`
    /// for every other activation.
    mutating func attemptPrimaryAction() -> Bool {
        guard isSuppressed else { return true }
        isSuppressed = false
        return false
    }

    /// Unconditionally clears suppression. Intended to be called only from
    /// a *deferred* context (see ``SemanticActionControl``'s use of
    /// `Task { @MainActor in }` from the falling edge of its long-press
    /// gesture state) — strictly after the current touch-up's own
    /// synchronous `Button` action, if any is going to fire in this same
    /// pass, has already had its chance to observe and consume the flag via
    /// ``attemptPrimaryAction()``. Deferring this call is what lets it never
    /// race with (or undo) that same-pass consumption, while still
    /// guaranteeing a drag-away-abandoned long press's suppression cannot
    /// outlive its own interaction to swallow a later, unrelated
    /// accessibility-driven activation.
    mutating func clearStaleSuppression() {
        isSuppressed = false
    }
}

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
/// `semanticFocusID` is reported alongside every dispatched outcome so a
/// direct tap/click/accessibility-activation on a target other than the
/// host's own current notion of focus still acts on the node the user
/// actually activated, rather than on a possibly-stale focus the host has
/// not yet caught up to via `@FocusState`.
///
/// ``ActionSuppressionState`` (see above) governs the interaction between
/// this control's simultaneous long-press gesture and `Button`'s own tap
/// recognizer; `isLongPressing` (backed by `LongPressGesture`'s own
/// `updating` state, which SwiftUI reports as `true` from the moment the
/// press begins — well before `minimumDuration` elapses and `onEnded`
/// fires, and `false` again once the press ends for any reason) drives both
/// of that state machine's edge-triggered transitions. (A separate
/// zero-distance `DragGesture` was considered for the "press began" signal
/// instead, but `DragGesture` is unavailable on tvOS; reusing
/// `LongPressGesture`'s own `updating` state keeps this control available on
/// every platform target.)
public struct SemanticActionControl<Label: View>: View {
    public let accessibilityLabel: Text
    public let semanticFocusID: SemanticFocusID
    public let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void
    @ViewBuilder public let label: () -> Label

    @State private var suppression = ActionSuppressionState()
    @GestureState private var isLongPressing = false

    public init(
        accessibilityLabel: Text,
        semanticFocusID: SemanticFocusID,
        onOutcome: @escaping (SemanticFocusID, SemanticDispatchOutcome) -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.semanticFocusID = semanticFocusID
        self.onOutcome = onOutcome
        self.label = label
    }

    public var body: some View {
        Button {
            if suppression.attemptPrimaryAction() {
                onOutcome(semanticFocusID, .command(.primaryAction))
            }
        } label: {
            label()
        }
        .simultaneousGesture(
            LongPressGesture()
                .updating($isLongPressing) { currentState, state, _ in
                    state = currentState
                }
                .onEnded { _ in
                    suppression.longPressSucceeded()
                    onOutcome(semanticFocusID, .command(.secondaryAction))
                }
        )
        .onChange(of: isLongPressing) { wasPressing, nowPressing in
            if !wasPressing, nowPressing {
                suppression.pressBegan()
            } else if wasPressing, !nowPressing {
                // Deferred so this can never race with (or undo) the same
                // touch-up's own synchronous `Button` action consuming the
                // flag first, when the press ended with a legitimate lift-off
                // inside the control's bounds; see `clearStaleSuppression`'s
                // documentation.
                Task { @MainActor in
                    suppression.clearStaleSuppression()
                }
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
