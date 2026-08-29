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

    /// The full decision for `SemanticActionControl`'s `isPressActive`
    /// falling/rising edge, extracted so the view's `.onChange` closure has
    /// no branching logic of its own left to get subtly wrong — it need only
    /// forward this call and, when told to, schedule the deferred clear.
    ///
    /// Returns whether the caller should schedule a *deferred* call to
    /// ``clearStaleSuppression()`` (never call it synchronously from here):
    /// `true` on the falling edge (press truly ended/cancelled), `false`
    /// otherwise. On the rising edge this also performs ``pressBegan()``
    /// synchronously, since that clears leftover state before this same new
    /// press's own gesture recognition or `Button` action can possibly run,
    /// so no deferral is needed or correct there.
    mutating func pressActiveDidChange(from wasActive: Bool, to isActive: Bool) -> Bool {
        if !wasActive, isActive {
            pressBegan()
            return false
        }
        return wasActive && !isActive
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
/// recognizer; `isPressActive` drives both of that state machine's
/// edge-triggered transitions.
///
/// `isPressActive` is **not** a bare `LongPressGesture`'s own `updating`
/// state: SwiftUI resets that the instant the press is *recognized* as a
/// long press (at `minimumDuration`), which is well before the finger
/// actually lifts — using it directly caused a real, reproduced double-
/// dispatch bug (the deferred suppression-clear below would run on the very
/// next main-actor turn *while the finger was still held down*, long before
/// `Button`'s own touch-up-triggered action could fire, so by the time it
/// did fire suppression had already been wrongly cleared). Instead,
/// `isPressActive` is driven by *sequencing* an effectively-instant first
/// `LongPressGesture` (so entering the gesture at all immediately satisfies
/// it) before a second phase whose `minimumDuration` is `.infinity` — that
/// second phase can only ever end by cancellation, which SwiftUI reports
/// (by resetting this `@GestureState` to `false`) exactly when the
/// underlying touch truly ends, for any reason (lift-off or cancel),
/// regardless of whether an earlier, independent `LongPressGesture` (below)
/// already recognized a long press while the finger was still down.
/// `LongPressGesture` (rather than `DragGesture`) is used for both phases of
/// this sequence because `DragGesture` is unavailable on tvOS.
///
/// A second, distinct failure mode of the same shape exists on every
/// non-tvOS platform: `LongPressGesture`'s `maximumDistance` parameter
/// defaults to 10 points, and — unlike `minimumDuration` — this default
/// applies to *both* phases of the sequence above, including the
/// `.infinity`-duration second phase meant to track the real touch
/// lifecycle. Ordinary finger/cursor drift while a press is still held,
/// well within the target's own bounds (for example after the semantic
/// long press below has already succeeded), exceeds that 10pt tolerance
/// and fails the *lifecycle* gesture on distance alone — resetting
/// `isPressActive` to `false`, and thus running the deferred clear, while
/// the touch is still physically down, long before the real lift. That
/// reproduces the exact same double-dispatch this type exists to prevent,
/// just via drift instead of via early gesture recognition. `tvOS` is
/// unaffected only because its `LongPressGesture` has no `maximumDistance`
/// initializer or property at all (there is no drift to speak of on the
/// Siri Remote's directional/trackpad input in the sense a touchscreen or
/// pointer has); every other platform must explicitly pass
/// `maximumDistance: .greatestFiniteMagnitude` (not `.infinity`, which SwiftUI's
/// internal distance arithmetic is not documented to handle safely; a huge
/// but finite sentinel is never actually approached by any real on-screen
/// coordinate delta) to both phases so this lifecycle gesture, like
/// `minimumDuration` before it, can only ever end at the real touch/pointer
/// up or cancel — never on distance. The separate, independent
/// `LongPressGesture` below that decides whether a press counts as
/// ``SemanticCommand/secondaryAction`` intentionally keeps its own default
/// 10pt tolerance; only the lifecycle-tracking gesture's tolerance is
/// widened.
public struct SemanticActionControl<Label: View>: View {
    public let accessibilityLabel: Text
    public let semanticFocusID: SemanticFocusID
    public let onOutcome: (SemanticFocusID, SemanticDispatchOutcome) -> Void
    @ViewBuilder public let label: () -> Label

    @State private var suppression = ActionSuppressionState()
    @GestureState private var isPressActive = false

    /// How long a press must be held before it counts as the long-press
    /// ``SemanticCommand/secondaryAction`` rather than a short tap.
    private static var secondaryActionThreshold: Double {
        0.5
    }

    #if os(tvOS)
        /// tvOS's `LongPressGesture` has no `maximumDistance` initializer or
        /// property at all, so its plain `init(minimumDuration:)` is already
        /// "distance-free" and needs no adjustment — see this type's
        /// top-level doc comment.
        static var lifecyclePressPhase: LongPressGesture {
            LongPressGesture(minimumDuration: 0)
        }

        static var lifecycleHoldPhase: LongPressGesture {
            LongPressGesture(minimumDuration: .infinity)
        }
    #else
        /// `internal`, not `private`: exposed so tests can assert directly on
        /// the actual `maximumDistance` this type constructs its lifecycle
        /// gesture with, rather than only on derived state-machine behavior —
        /// a wiring regression that silently reverts to the 10pt default
        /// would otherwise pass every ``ActionSuppressionState``-level test.
        static var lifecyclePressPhase: LongPressGesture {
            LongPressGesture(minimumDuration: 0, maximumDistance: .greatestFiniteMagnitude)
        }

        static var lifecycleHoldPhase: LongPressGesture {
            LongPressGesture(minimumDuration: .infinity, maximumDistance: .greatestFiniteMagnitude)
        }
    #endif

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
        // Dispatches the secondary action exactly once, right when the long
        // press is recognized — independent of `isPressActive` below, which
        // exists purely to track the *real* touch lifecycle for suppression
        // timing, not to gate this dispatch.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: Self.secondaryActionThreshold)
                .onEnded { _ in
                    suppression.longPressSucceeded()
                    onOutcome(semanticFocusID, .command(.secondaryAction))
                }
        )
        .simultaneousGesture(
            Self.lifecyclePressPhase
                .sequenced(before: Self.lifecycleHoldPhase)
                .updating($isPressActive) { _, state, _ in
                    state = true
                }
        )
        .onChange(of: isPressActive) { wasActive, nowActive in
            if suppression.pressActiveDidChange(from: wasActive, to: nowActive) {
                // Deferred so this can never race with (or undo) this same
                // touch-up's own synchronous `Button` action consuming the
                // flag first, when the lift lands inside the control's
                // bounds; see `clearStaleSuppression`'s documentation. Unlike
                // the historical, buggy signal this replaces, `isPressActive`
                // only turns `false` at the *real* touch-up/cancel, so this
                // deferred call is scheduled at the correct time instead of
                // while the finger is still held down.
                Task { @MainActor in
                    suppression.clearStaleSuppression()
                }
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
