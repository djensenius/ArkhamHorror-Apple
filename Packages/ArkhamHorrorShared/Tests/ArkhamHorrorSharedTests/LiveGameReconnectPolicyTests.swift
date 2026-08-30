@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic coverage for ``LiveGameReconnectPolicy``'s pure backoff/jitter
/// arithmetic -- no clock, random source, task, or `AppModel` involved, so every
/// bound is asserted exactly for a given `(attempt, unitInterval)` pair.
@Suite("LiveGameReconnectPolicy")
struct LiveGameReconnectPolicyTests {
    @Test("The delay ceiling doubles per attempt starting from the initial ceiling")
    func delayCeilingDoublesPerAttempt() {
        #expect(
            LiveGameReconnectPolicy.delayCeiling(forAttempt: 0)
                == LiveGameReconnectPolicy.initialDelayCeiling
        )
        #expect(LiveGameReconnectPolicy.delayCeiling(forAttempt: 1) == .seconds(2))
        #expect(LiveGameReconnectPolicy.delayCeiling(forAttempt: 2) == .seconds(4))
        #expect(LiveGameReconnectPolicy.delayCeiling(forAttempt: 3) == .seconds(8))
    }

    @Test("The delay ceiling never exceeds the maximum ceiling, however large the attempt")
    func delayCeilingIsCappedAtMaximum() {
        #expect(
            LiveGameReconnectPolicy.delayCeiling(forAttempt: 10)
                == LiveGameReconnectPolicy.maximumDelayCeiling
        )
        #expect(
            LiveGameReconnectPolicy.delayCeiling(forAttempt: 1000)
                == LiveGameReconnectPolicy.maximumDelayCeiling
        )
    }

    @Test("A unit interval of 0 produces a zero delay for any attempt")
    func zeroUnitIntervalProducesZeroDelay() {
        for attempt in 0 ... 6 {
            #expect(
                LiveGameReconnectPolicy.jitteredDelay(forAttempt: attempt, unitInterval: 0)
                    == .zero
            )
        }
    }

    @Test("A unit interval of 1 produces exactly the attempt's delay ceiling")
    func fullUnitIntervalProducesTheCeilingExactly() {
        for attempt in 0 ... 6 {
            #expect(
                LiveGameReconnectPolicy.jitteredDelay(forAttempt: attempt, unitInterval: 1)
                    == LiveGameReconnectPolicy.delayCeiling(forAttempt: attempt)
            )
        }
    }

    @Test("A fractional unit interval produces a proportionally scaled delay")
    func fractionalUnitIntervalScalesTheCeilingProportionally() {
        // attempt 1's ceiling is 2 seconds; half the jitter fraction must be 1 second.
        #expect(
            LiveGameReconnectPolicy.jitteredDelay(forAttempt: 1, unitInterval: 0.5) == .seconds(1)
        )
    }

    @Test("An out-of-range unit interval is clamped rather than trusted")
    func outOfRangeUnitIntervalIsClamped() {
        #expect(
            LiveGameReconnectPolicy.jitteredDelay(forAttempt: 0, unitInterval: -5) == .zero
        )
        #expect(
            LiveGameReconnectPolicy.jitteredDelay(forAttempt: 0, unitInterval: 5)
                == LiveGameReconnectPolicy.delayCeiling(forAttempt: 0)
        )
    }

    @Test("Every jittered delay for any attempt/unitInterval pair stays within [0, ceiling]")
    func everyJitteredDelayStaysWithinBounds() {
        for attempt in 0 ... 8 {
            let ceiling = LiveGameReconnectPolicy.delayCeiling(forAttempt: attempt)
            for tenth in 0 ... 10 {
                let unitInterval = Double(tenth) / 10
                let delay = LiveGameReconnectPolicy.jitteredDelay(
                    forAttempt: attempt, unitInterval: unitInterval
                )
                #expect(delay >= .zero)
                #expect(delay <= ceiling)
            }
        }
    }

    @Test("The maximum attempts bound is small enough to rule out an unbounded retry storm")
    func maximumAttemptsIsBounded() {
        #expect(LiveGameReconnectPolicy.maximumAttempts > 0)
        #expect(LiveGameReconnectPolicy.maximumAttempts <= 10)
    }
}
