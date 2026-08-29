@testable import ArkhamHorrorShared
import Testing
#if canImport(SwiftUI)
    import SwiftUI
#endif

/// Coverage for the *actual SwiftUI gesture configuration*
/// ``SemanticActionControl`` constructs for its `isPressActive` lifecycle
/// signal — as opposed to ``ActionSuppressionStateTests``, which covers the
/// pure state machine driven by that signal, but cannot by itself detect a
/// regression in how the signal is produced.
///
/// A reviewer reproduced a real double-dispatch: `LongPressGesture`'s
/// `maximumDistance` parameter defaults to 10 points on every platform
/// except tvOS (where no such parameter exists at all), and that default
/// silently also applied to the `.infinity`-duration second phase of the
/// sequenced gesture meant to track only the real touch-up/cancel — so
/// ordinary finger/cursor drift while a long press was still held (well
/// within the control's own bounds) failed that lifecycle gesture on
/// distance alone, resetting `isPressActive` to `false` — and thus running
/// the deferred suppression-clear — while the touch was still physically
/// down, long before the real lift. Neither the state-machine-level tests
/// nor a purely behavioral test can catch a silent revert to that default;
/// only asserting the actual configured value can, which this suite exists
/// to do directly on `SemanticActionControl`'s exposed
/// `lifecyclePressPhase`/`lifecycleHoldPhase` gesture instances.
///
/// This repo has no SwiftUI UI-testing harness, so real touch/pointer drift
/// cannot be synthesized end-to-end here; this is the closest
/// production-order regression achievable without one, and it does fail
/// against the pre-fix wiring (plain `LongPressGesture(minimumDuration:...)`
/// with its implicit 10pt default) that caused the reviewer's reproduction.
@Suite("SemanticActionControl — lifecycle gesture distance configuration")
@MainActor
struct SemanticActionControlGestureTests {
    #if !os(tvOS)
        @Test(
            """
            The non-tvOS lifecycle press phase tolerates unbounded drift, so it can \
            only end at a real touch/pointer down-to-up transition, never on distance \
            alone — this must fail if the wiring silently reverts to LongPressGesture's \
            10pt default
            """
        )
        func lifecyclePressPhaseToleratesUnboundedDrift() {
            let maximumDistance = SemanticActionControl<Text>.lifecyclePressPhase.maximumDistance
            #expect(maximumDistance == .greatestFiniteMagnitude)
        }

        @Test(
            """
            The non-tvOS lifecycle hold phase (the .infinity-duration second phase that \
            actually tracks the held touch through drift) tolerates unbounded drift, so \
            a completed long press's suppression cannot be cleared early by ordinary \
            movement while the finger/cursor remains down
            """
        )
        func lifecycleHoldPhaseToleratesUnboundedDrift() {
            let maximumDistance = SemanticActionControl<Text>.lifecycleHoldPhase.maximumDistance
            #expect(maximumDistance == .greatestFiniteMagnitude)
        }

        @Test(
            """
            The chosen sentinel is a huge but finite CGFloat (not .infinity, whose \
            propagation through SwiftUI's internal distance arithmetic is undocumented) \
            — so even an implausibly large on-screen coordinate delta's squared distance \
            never approaches it, confirming the sentinel is safe across any real \
            coordinate space without special-casing huge values
            """
        )
        func sentinelToleratesImplausiblyLargeCoordinateDeltas() {
            let hugeDelta = 1e10
            let hugeSquaredDistance = hugeDelta * hugeDelta
            #expect(hugeSquaredDistance.isFinite)
            #expect(hugeSquaredDistance < Double(CGFloat.greatestFiniteMagnitude))
            let maximumDistance = SemanticActionControl<Text>.lifecyclePressPhase.maximumDistance
            #expect(Double(maximumDistance) > hugeSquaredDistance)
        }

        @Test(
            """
            The production secondary-action recognizer (SemanticActionControl.\
            secondaryActionRecognizer, the exact instance body attaches its \
            secondaryAction-dispatching .onEnded handler to) intentionally keeps its \
            own default 10pt tolerance — only the lifecycle-tracking gesture's \
            tolerance was widened, not this one. Inspecting the production property \
            itself (rather than an independently-constructed local LongPressGesture) \
            means this fails if body's own wiring is ever changed, e.g. if this \
            tolerance were mistakenly widened alongside the lifecycle phases above
            """
        )
        func secondaryActionRecognizerRetainsDefaultTolerance() {
            let maximumDistance = SemanticActionControl<Text>.secondaryActionRecognizer
                .maximumDistance
            #expect(maximumDistance == 10)
        }
    #endif
}
