import Foundation
import Testing

/// Round 8 mutation-resistant coverage for `SubprocessDeadlineGuard`'s own mechanics, kept
/// separate from the (expensive, quadratic-loop-specific) victims in
/// ``LosslessJSONNumberExtremeExponentTests`` so each of these can stay fast and focused:
///
/// - **HIGH**: an unsupported host (Apple's classic bare `xctest` agent under `xcodebuild
///   test`, fingerprinted by a `CommandLine.arguments` of length 1) must be detected and
///   skipped *before* any subprocess is launched, never mistaken for a genuine timeout.
/// - **LOW**: a bare zero exit code must never be trusted as proof the victim's intended
///   code path actually ran; a missing/mismatched trigger environment-variable key, or a
///   `--filter` that matches zero tests, must both be caught by the completion-sentinel
///   check, not silently reported as a pass.
private enum SelfTestVictimEnvironmentKey {
    /// Deliberately distinct from `SubprocessDeadlineGuard.completionSentinelEnvironmentKey`
    /// -- this key only tells the self-test victim *what to do*; the sentinel key (shared,
    /// typed, and owned by `SubprocessDeadlineGuard` itself) is how it proves it did it.
    static let mode = "SUBPROCESS_DEADLINE_GUARD_SELFTEST_MODE"
}

private enum SelfTestVictimMode: String {
    /// Finishes immediately and records completion -- the expected "everything worked" path.
    case succeed
    /// Spins forever; only OS-level termination by the parent's deadline can end this, the
    /// same non-cooperative-cancellation problem `SubprocessDeadlineGuard` exists to solve.
    case hang
    /// Fails its own assertion, so the child process exits nonzero on its own.
    case fail
}

/// This is never invoked directly by the full-suite run itself: like the quadratic-guard
/// victims, it is a no-op (instant pass) unless `SelfTestVictimEnvironmentKey.mode` is
/// present, which only the tests below set, and only in the dedicated child process each
/// launches via `SubprocessDeadlineGuard.runFiltered`. Its function name doubles as the
/// `--filter` argument that isolates it from the rest of the suite in that child process.
@Test("Self-test victim for SubprocessDeadlineGuard's own mechanics tests (subprocess-only)")
func subprocessDeadlineGuardSelfTestVictim() {
    guard
        let raw = ProcessInfo.processInfo.environment[SelfTestVictimEnvironmentKey.mode],
        let mode = SelfTestVictimMode(rawValue: raw)
    else {
        return
    }
    switch mode {
    case .succeed:
        SubprocessDeadlineGuard.recordVictimCompletion()
    case .hang:
        while true {
            Thread.sleep(forTimeInterval: 0.05)
        }
    case .fail:
        #expect(Bool(false), "Intentional self-test failure to exercise child-failure detection.")
    }
}

@Suite("SubprocessDeadlineGuard mechanics")
struct SubprocessDeadlineGuardMechanicsTests {
    /// Fails the test with a descriptive message unless `body` throws a
    /// `SubprocessDeadlineGuardError` matching `matches`. Centralizing this keeps each
    /// individual test focused on which outcome it expects, not boilerplate error-unwrapping.
    ///
    /// These tests need to actually launch a real subprocess to observe real timeout/
    /// failure/completion-unproven behavior, so -- exactly like the quadratic-guard tests
    /// in ``LosslessJSONNumberExtremeExponentTests`` -- they are just as unable to run
    /// under an unsupported host (e.g. `xcodebuild test` against this package's bare-argv
    /// `xctest` scheme) as the mechanism they are testing. A `.skippedUnsupportedHost`
    /// outcome is therefore treated the same honest, non-fatal way here: a visible warning,
    /// not a false failure and not a silently-skipped assertion.
    private func expectGuardError(
        _ expectedDescription: String,
        matches: (SubprocessDeadlineGuardError) -> Bool,
        body: () throws -> SubprocessDeadlineGuardOutcome
    ) {
        do {
            let outcome = try body()
            if case let .skippedUnsupportedHost(reason) = outcome {
                recordSkippedHostWarning(reason)
                return
            }
            Issue.record(
                Comment(
                    rawValue: "Expected \(expectedDescription), but runFiltered returned " +
                        "\(outcome) instead of throwing."
                )
            )
        } catch let error as SubprocessDeadlineGuardError where matches(error) {
            // Expected.
        } catch {
            Issue.record("Expected \(expectedDescription), got \(error) instead.")
        }
    }

    /// Shared with every test below that needs a real subprocess launch: records a visible,
    /// non-fatal warning-severity issue rather than either failing or silently no-op'ing
    /// when this guard's host-detection determines no subprocess can be launched at all.
    private func recordSkippedHostWarning(_ reason: String) {
        Issue.record(
            Comment(
                rawValue: "Skipped: unsupported host (\(reason)). This test's own semantic " +
                    "assertion (not a subprocess-timing one) is exactly the case this guard " +
                    "cannot exercise under this host."
            ),
            severity: .warning
        )
    }

    // MARK: - Host detection (round 8 HIGH)

    @Test("isSupportedReExecHost requires more than a bare single-argument argv")
    func isSupportedReExecHostRequiresMoreThanBareArgv() {
        // The empty and single-element cases are the fingerprint of Apple's classic bare
        // `xctest` agent under Xcode/xcodebuild -- no CLI arguments at all.
        #expect(SubprocessDeadlineGuard.isSupportedReExecHost(hostArguments: []) == false)
        #expect(
            SubprocessDeadlineGuard
                .isSupportedReExecHost(hostArguments: ["/path/to/xctest"]) == false
        )
        // Anything with a genuine argument list -- as `swift test`/SwiftPM's
        // `swiftpm-testing-helper` always produces, filtered or not -- is supported.
        #expect(
            SubprocessDeadlineGuard.isSupportedReExecHost(
                hostArguments: ["/path/to/swiftpm-testing-helper", "--filter", "X"]
            ) == true
        )
        #expect(
            SubprocessDeadlineGuard.isSupportedReExecHost(
                hostArguments: ["/path", "--test-bundle-path", "/y"]
            ) == true
        )
    }

    @Test("An unsupported host is skipped cleanly, without ever attempting to launch a subprocess")
    func unsupportedHostSkipsWithoutLaunchingSubprocess() throws {
        // If the host-support check were bypassed, `Process.run()` would throw synchronously
        // for this nonexistent executable path rather than hang -- so a clean, non-throwing
        // `.skippedUnsupportedHost` return (rather than a caught launch-failure error) is
        // itself deterministic proof no subprocess launch was attempted.
        let outcome = try SubprocessDeadlineGuard.runFiltered(
            victimFilter: "subprocessDeadlineGuardSelfTestVictim",
            additionalEnvironment: [
                SelfTestVictimEnvironmentKey.mode: SelfTestVictimMode.hang.rawValue,
            ],
            deadlineSeconds: 20,
            hostArguments: ["/no/such/executable/on/this/machine"]
        )
        guard case let .skippedUnsupportedHost(reason) = outcome else {
            Issue.record("Expected .skippedUnsupportedHost, got \(outcome) instead.")
            return
        }
        #expect(reason.contains("1 argument"))
    }

    // MARK: - Completion-sentinel proof (round 8 LOW)

    @Test("A victim that finishes and records completion yields .completed")
    func victimThatCompletesYieldsCompleted() throws {
        let outcome = try SubprocessDeadlineGuard.runFiltered(
            victimFilter: "subprocessDeadlineGuardSelfTestVictim",
            additionalEnvironment: [
                SelfTestVictimEnvironmentKey.mode: SelfTestVictimMode.succeed.rawValue,
            ],
            deadlineSeconds: 20
        )
        if case let .skippedUnsupportedHost(reason) = outcome {
            recordSkippedHostWarning(reason)
            return
        }
        #expect(outcome == .completed)
    }

    @Test("A victim that hangs past the deadline is terminated and reported as timed out")
    func victimThatHangsIsTimedOut() {
        expectGuardError(
            ".timedOut",
            matches: {
                if case .timedOut = $0 {
                    true
                } else {
                    false
                }
            },
            body: {
                try SubprocessDeadlineGuard.runFiltered(
                    victimFilter: "subprocessDeadlineGuardSelfTestVictim",
                    additionalEnvironment: [
                        SelfTestVictimEnvironmentKey.mode: SelfTestVictimMode.hang.rawValue,
                    ],
                    deadlineSeconds: 2
                )
            }
        )
    }

    @Test("A victim whose own assertions fail is reported as a child failure")
    func victimThatFailsIsChildFailed() {
        expectGuardError(
            ".childFailed",
            matches: {
                if case .childFailed = $0 {
                    true
                } else {
                    false
                }
            },
            body: {
                try SubprocessDeadlineGuard.runFiltered(
                    victimFilter: "subprocessDeadlineGuardSelfTestVictim",
                    additionalEnvironment: [
                        SelfTestVictimEnvironmentKey.mode: SelfTestVictimMode.fail.rawValue,
                    ],
                    deadlineSeconds: 20
                )
            }
        )
    }

    @Test("A filter matching zero tests fails, not a false pass")
    func filterMatchingNothingFails() {
        // Empirically, the `swiftpm-testing-helper` host this guard replays exits nonzero
        // (observed: 69) when `--filter` matches zero tests -- so this is already caught by
        // the ordinary child-failure path. Either way, the key invariant this guards is
        // that a filter selecting nothing must never be silently treated as a pass.
        expectGuardError(
            "a failure (not .completed)",
            matches: { _ in true },
            body: {
                try SubprocessDeadlineGuard.runFiltered(
                    victimFilter: "noSuchSelfTestVictimXYZ123NeverExists",
                    additionalEnvironment: [
                        SelfTestVictimEnvironmentKey.mode: SelfTestVictimMode.succeed.rawValue,
                    ],
                    deadlineSeconds: 20
                )
            }
        )
    }

    @Test("A mismatched trigger environment-variable key is reported as completion-unproven")
    func mismatchedTriggerEnvironmentKeyIsCompletionUnproven() {
        // Simulates exactly the producer/consumer drift this mechanism defends against: the
        // victim's own lookup key never matches what was actually set, so it returns
        // immediately without recording completion -- exit 0, but unproven.
        expectGuardError(
            ".completionUnproven",
            matches: {
                if case .completionUnproven = $0 {
                    true
                } else {
                    false
                }
            },
            body: {
                try SubprocessDeadlineGuard.runFiltered(
                    victimFilter: "subprocessDeadlineGuardSelfTestVictim",
                    additionalEnvironment: [
                        "THIS_KEY_DOES_NOT_MATCH_THE_VICTIMS_OWN_LOOKUP":
                            SelfTestVictimMode.succeed.rawValue,
                    ],
                    deadlineSeconds: 20
                )
            }
        )
    }
}
