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
}
