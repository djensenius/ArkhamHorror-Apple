@testable import ArkhamHorrorShared
import Testing

/// Coverage for ``ActionSuppressionState``, the pure state machine behind
/// ``SemanticActionControl``'s long-press/primary-action interaction —
/// extracted specifically so its full lifecycle (including interleavings
/// that would require synthesizing real SwiftUI touch/gesture events to
/// exercise directly) is independently unit-testable.
///
/// Every assertion below binds ``ActionSuppressionState/attemptPrimaryAction()``'s
/// result to a local `let` before passing it to `#expect`, rather than
/// calling the mutating method directly inside the macro's argument: the
/// `#expect` macro expansion cannot bind a mutating call's `inout` receiver.
@Suite("ActionSuppressionState — long-press/primary-action suppression")
struct ActionSuppressionStateTests {
    @Test("A normal tap (no long press) always dispatches the primary action")
    func normalTapDispatchesPrimaryAction() {
        var state = ActionSuppressionState()
        state.pressBegan()
        let dispatched = state.attemptPrimaryAction()
        #expect(dispatched)
    }

    @Test("A successful long press suppresses exactly the one following primary action")
    func successfulLongPressSuppressesExactlyOneFollowingPrimaryAction() {
        var state = ActionSuppressionState()
        state.pressBegan()
        state.longPressSucceeded()
        // The spurious follow-on Button tap after a completed long press:
        // suppressed exactly once.
        let firstAttempt = state.attemptPrimaryAction()
        #expect(!firstAttempt)
        // A second, independent activation right after is never itself
        // suppressed — the flag does not "stick" beyond the one tap it was
        // meant to swallow.
        let secondAttempt = state.attemptPrimaryAction()
        #expect(secondAttempt)
    }

    @Test(
        """
        A long press that succeeds then is dragged away and lifted outside (no primary \
        action ever fires to consume the flag) still clears via the deferred \
        stale-suppression path, so a later accessibility activation is not swallowed
        """
    )
    func longPressSuccessThenDragAwayThenLaterAccessibilityActivationIsNotSwallowed() {
        var state = ActionSuppressionState()
        state.pressBegan()
        state.longPressSucceeded()
        // Button's own action never fires for this interaction (the lift
        // happened outside its bounds) — only the deferred, gesture-end
        // triggered clear can reset the flag here.
        state.clearStaleSuppression()
        // A later, wholly separate VoiceOver/Switch Control/keyboard
        // activation must not be swallowed by the earlier long press.
        let laterActivation = state.attemptPrimaryAction()
        #expect(laterActivation)
    }

    @Test("clearStaleSuppression is a harmless no-op when a same-turn tap already consumed it")
    func clearStaleSuppressionIsANoOpWhenAlreadyConsumed() {
        var state = ActionSuppressionState()
        state.pressBegan()
        state.longPressSucceeded()
        // Simulates Button's own action winning the race and consuming the
        // flag before the deferred clear runs.
        let firstAttempt = state.attemptPrimaryAction()
        #expect(!firstAttempt)
        state.clearStaleSuppression()
        // Still available for the *next* activation, exactly as if the
        // deferred clear had never run at all.
        let nextActivation = state.attemptPrimaryAction()
        #expect(nextActivation)
    }

    @Test("A new press's rising edge clears any suppression left over from an earlier one")
    func newPressRisingEdgeClearsLeftoverSuppression() {
        var state = ActionSuppressionState()
        state.pressBegan()
        state.longPressSucceeded()
        // The earlier long press's follow-on tap is never delivered at all
        // (e.g. a completely new, unrelated press begins first).
        state.pressBegan()
        let dispatched = state.attemptPrimaryAction()
        #expect(dispatched)
    }

    @Test("Repeated long-press/tap cycles never leak suppression across interactions")
    func repeatedLongPressTapCyclesNeverLeakSuppression() {
        var state = ActionSuppressionState()
        for _ in 0 ..< 5 {
            state.pressBegan()
            state.longPressSucceeded()
            let suppressedAttempt = state.attemptPrimaryAction()
            #expect(!suppressedAttempt)
            state.clearStaleSuppression()
            state.pressBegan()
            let normalAttempt = state.attemptPrimaryAction()
            #expect(normalAttempt)
        }
    }

    @Test("Repeated ordinary taps never suppress each other")
    func repeatedOrdinaryTapsNeverSuppressEachOther() {
        var state = ActionSuppressionState()
        for _ in 0 ..< 5 {
            state.pressBegan()
            let dispatched = state.attemptPrimaryAction()
            #expect(dispatched)
            state.clearStaleSuppression()
        }
    }

    // MARK: - Production event order (see SemanticActionControl's gesture

    // composition doc comments)

    @Test(
        """
        Production event order: press begins, long press succeeds while still \
        held, then the real touch-up fires Button's action and schedules the \
        deferred clear — the deferred clear must not run before Button's own \
        action observes suppression, so exactly one primary is suppressed
        """
    )
    func productionEventOrderSuppressesExactlyOneFollowOnTapAtTrueLift() {
        // `SemanticActionControl.body`'s corrected `isPressActive` only goes
        // false at the *real* touch-up — the same moment `Button`'s own
        // action fires for a lift landing inside its bounds. Both are
        // dispatched synchronously from that one touch-up event; the clear
        // itself is scheduled via `Task { @MainActor in }`, which always
        // runs strictly *after* every synchronous signal from that same
        // event — so `attemptPrimaryAction()` (Button's action) must be
        // driven here *before* `clearStaleSuppression()` (the deferred
        // clear) to faithfully reproduce production ordering, even though
        // the falling-edge signal that *schedules* the clear is observed
        // first.
        var state = ActionSuppressionState()
        state.pressBegan()
        state.longPressSucceeded()
        // `.onChange(of: isPressActive)` observes the falling edge here and
        // schedules (but does not yet run) the deferred clear.
        let scheduledClear = state.pressActiveDidChange(from: true, to: false)
        #expect(scheduledClear)
        // Button's own action, synchronously part of the same touch-up:
        let dispatchedAtRealLift = state.attemptPrimaryAction()
        #expect(!dispatchedAtRealLift)
        // Only now does the previously-scheduled deferred clear actually
        // run (on the next main-actor turn) — a harmless no-op, since
        // Button's action already consumed the flag above.
        state.clearStaleSuppression()
        // A later, wholly unrelated activation is unaffected.
        let laterActivation = state.attemptPrimaryAction()
        #expect(laterActivation)
    }

    @Test(
        """
        Historical bug regression: if the touch-active falling edge were \
        (wrongly) signalled while the finger is still down — as the old, \
        buggy bare LongPressGesture-based signal did, resetting at recognition \
        rather than true lift — the deferred clear would run before Button's \
        real, later touch-up action, incorrectly un-suppressing it and \
        causing a double dispatch
        """
    )
    func historicalPrematureFallingEdgeWouldHaveCausedDoubleDispatch() {
        // This test intentionally reproduces the *buggy* ordering that
        // `SemanticActionControl`'s original `isLongPressing` signal
        // produced (falling edge observed — and its deferred clear run —
        // while the touch was still conceptually held), to document exactly
        // why `isPressActive`'s corrected, true-lift-only falling edge (see
        // the production-order test above, and the gesture composition's
        // doc comments) is load-bearing: this is the double-dispatch the
        // reviewer reproduced, not a hypothetical.
        var state = ActionSuppressionState()
        state.pressBegan()
        state.longPressSucceeded()
        // The bug: the falling edge (and thus the deferred clear) fires
        // immediately here, on the very next main-actor turn, while the
        // finger is still physically down — long before the real touch-up.
        let scheduledClear = state.pressActiveDidChange(from: true, to: false)
        #expect(scheduledClear)
        state.clearStaleSuppression()
        // ... arbitrarily many main-actor turns pass while the finger
        // remains down ...
        // Only now, at the real (later) lift, does Button's tap fire:
        let dispatchedAtRealLift = state.attemptPrimaryAction()
        // Demonstrates the bug mechanism: suppression was already cleared
        // long before this point, so the completed long press's own
        // follow-on tap is incorrectly *not* suppressed.
        #expect(dispatchedAtRealLift)
    }

    @Test("pressActiveDidChange's rising edge clears stale suppression, requests no deferred clear")
    func pressActiveDidChangeRisingEdgeClearsAndRequestsNoDeferral() {
        var state = ActionSuppressionState()
        state.pressBegan()
        state.longPressSucceeded()
        // A brand new press begins (rising edge) before anything consumed
        // the earlier long press's suppression flag.
        let scheduledClear = state.pressActiveDidChange(from: false, to: true)
        #expect(!scheduledClear)
        // The rising edge itself already cleared it — this new press's own
        // eventual tap is not suppressed by the unrelated earlier one.
        let dispatched = state.attemptPrimaryAction()
        #expect(dispatched)
    }

    // MARK: - Drift-related scenarios (see SemanticActionControlGestureTests

    // for the actual SwiftUI gesture-configuration fix this state sequence depends on)

    @Test(
        """
        Pre-success drift: the finger/cursor moves before the semantic 0.5s long press \
        recognizes at all, so longPressSucceeded() is never called; lifting inside the \
        control still dispatches a normal, unsuppressed primary action, exactly like an \
        ordinary short tap
        """
    )
    func preSuccessDriftNeverSuppressesTheEventualLift() {
        var state = ActionSuppressionState()
        state.pressBegan()
        // Drift happens here, before the 0.5s threshold — the semantic
        // long-press recognizer fails on distance and never calls
        // longPressSucceeded(); no suppression is ever armed.
        let dispatchedAtLift = state.attemptPrimaryAction()
        #expect(dispatchedAtLift)
    }

    @Test(
        """
        Drag out and back in, then lift inside: with the lifecycle gesture's distance \
        tolerance fixed (see SemanticActionControlGestureTests), \
        isPressActive only falls at the real lift regardless of intermediate drift, so \
        a long press that already succeeded is still suppressed exactly once at that \
        real, later lift — never early, from the drift itself
        """
    )
    func dragOutAndBackThenLiftInsideStillSuppressesExactlyOnceAtRealLift() {
        var state = ActionSuppressionState()
        state.pressBegan()
        state.longPressSucceeded()
        // Drift (out of and back into the control's bounds) does not, by
        // itself, produce any falling edge now that the lifecycle gesture
        // tolerates it — so nothing is observed here at all until the real
        // lift below.
        let dispatchedAtRealLift = state.attemptPrimaryAction()
        #expect(!dispatchedAtRealLift)
        let scheduledClear = state.pressActiveDidChange(from: true, to: false)
        #expect(scheduledClear)
        state.clearStaleSuppression()
        let laterActivation = state.attemptPrimaryAction()
        #expect(laterActivation)
    }

    @Test(
        """
        Cancellation after a successful long press (e.g. an incoming system alert, not a \
        drag-away lift) never fires Button's own action either — the deferred clear from \
        the falling edge is still the only thing that resets suppression, and a later, \
        unrelated activation (including one driven by a subsequent accessibility action) \
        is never swallowed
        """
    )
    func cancellationAfterSuccessNeverLeavesSuppressionStuck() {
        var state = ActionSuppressionState()
        state.pressBegan()
        state.longPressSucceeded()
        let scheduledClear = state.pressActiveDidChange(from: true, to: false)
        #expect(scheduledClear)
        state.clearStaleSuppression()
        let accessibilityActivation = state.attemptPrimaryAction()
        #expect(accessibilityActivation)
    }
}
