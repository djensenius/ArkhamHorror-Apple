@testable import ArkhamHorrorShared
import Testing

/// Tests for ``conditionalCommandClosure``, the platform-independent
/// decision extracted from ``SemanticSiriRemoteInput``'s identity-
/// preserving `.onExitCommand`/`.onPlayPauseCommand` wiring. This function
/// has zero platform dependency, unlike its tvOS-only consumer, so it is
/// the one part of that fix directly exercisable via `swift test` on any
/// host — see this type's own documentation for why full SwiftUI view-
/// identity preservation itself remains outside what this repo's test
/// tooling (no UI-testing/tvOS-simulator harness) can automate.
@Suite("conditionalCommandClosure")
struct ConditionalCommandClosureTests {
    @Test("false yields nil — the system default is left free to run")
    func disabledYieldsNil() {
        let result = conditionalCommandClosure(isEnabled: false) { Issue.record("should not run") }
        #expect(result == nil)
    }

    @Test("true yields a closure that invokes the supplied action exactly once")
    func enabledYieldsInvokableClosure() {
        var invocationCount = 0
        let result = conditionalCommandClosure(isEnabled: true) { invocationCount += 1 }
        #expect(result != nil)
        result?()
        #expect(invocationCount == 1)
    }

    @Test("false -> true -> false reproduces the toggle sequence a host re-render can produce")
    func falseTrueFalseSequenceMatchesEachState() {
        var invocationCount = 0
        let action = { invocationCount += 1 }

        let first = conditionalCommandClosure(isEnabled: false, perform: action)
        #expect(first == nil)

        let second = conditionalCommandClosure(isEnabled: true, perform: action)
        #expect(second != nil)
        second?()
        #expect(invocationCount == 1)

        let third = conditionalCommandClosure(isEnabled: false, perform: action)
        #expect(third == nil)
        // No stray invocation could have happened between toggles: the
        // count only ever advances when a caller actually invokes a
        // non-nil result, never merely from computing one.
        #expect(invocationCount == 1)
    }

    @Test("repeated calls at the same isEnabled value are independently invokable")
    func repeatedEnabledCallsAreIndependentlyInvokable() {
        var firstCount = 0
        var secondCount = 0

        let first = conditionalCommandClosure(isEnabled: true) { firstCount += 1 }
        let second = conditionalCommandClosure(isEnabled: true) { secondCount += 1 }

        first?()
        first?()
        second?()

        #expect(firstCount == 2)
        #expect(secondCount == 1)
    }
}
