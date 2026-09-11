import Foundation

enum SubprocessDeadlineTermination: Equatable {
    case exitedDuringGrace
    case killedAfterGrace
}

/// Errors surfaced by ``SubprocessDeadlineGuard``.
enum SubprocessDeadlineGuardError: Error, CustomStringConvertible {
    case timedOut(
        afterSeconds: Double,
        termination: SubprocessDeadlineTermination
    )
    case childFailed(exitCode: Int32)
    case completionUnproven
    case launchFailed(code: Int32)
    case signalFailed(signal: Int32, code: Int32)
    case waitFailed(code: Int32)
    case reapTimedOut(pid: Int32, afterSeconds: Double)
    case terminationUnconfirmed(pid: Int32)

    var description: String {
        switch self {
        case let .timedOut(afterSeconds, termination):
            switch termination {
            case .exitedDuringGrace:
                "Subprocess exceeded the \(afterSeconds)s deadline and exited during the " +
                    "bounded SIGTERM grace period."
            case .killedAfterGrace:
                "Subprocess exceeded the \(afterSeconds)s deadline, ignored SIGTERM, and " +
                    "was killed with SIGKILL after the bounded grace period."
            }
        case let .childFailed(exitCode):
            "Subprocess's own test assertions failed or it crashed (exit code \(exitCode))."
        case .completionUnproven:
            "Subprocess exited successfully but never created the completion-sentinel file, " +
                "so its intended victim code path is not proven to have actually run. This " +
                "happens if `--filter` matched zero tests, or if the victim's own " +
                "environment-variable trigger was missing/mismatched -- both exit 0 " +
                "immediately without doing any of the work this deadline is supposed to be " +
                "timing, which would otherwise be silently misreported as a genuine pass."
        case let .launchFailed(code):
            "Subprocess could not be launched (error code \(code))."
        case let .signalFailed(signal, code):
            "Could not send signal \(signal) to the retained child process group " +
                "(error code \(code))."
        case let .waitFailed(code):
            "Could not observe or reap the retained child process (error code \(code))."
        case let .reapTimedOut(pid, afterSeconds):
            "Child process \(pid) exited but could not be reaped within " +
                "\(afterSeconds)s."
        case let .terminationUnconfirmed(pid):
            "SIGKILL was sent to child process \(pid), but its termination could not be " +
                "confirmed within the bounded SIGKILL observation window."
        }
    }
}

/// The result of a supported, completed ``SubprocessDeadlineGuard/runFiltered`` invocation,
/// versus one that could not be attempted at all because the current process was not
/// launched by a host this guard knows how to re-exec.
enum SubprocessDeadlineGuardOutcome: Equatable {
    /// The victim ran in a genuinely separate process, proved (via the completion
    /// sentinel) that its intended code path executed, and finished within the deadline.
    case completed
    /// No subprocess was launched at all: the current process's own launch arguments do
    /// not look like a re-exec-compatible SwiftPM test-driver invocation (see
    /// ``SubprocessDeadlineGuard/isSupportedReExecHost(hostArguments:)``). Callers should
    /// treat this as a non-fatal, informative skip -- e.g. via `Issue.record(_:severity:
    /// .warning)` -- rather than either a failure or a silent no-op, while still relying on
    /// whatever in-process semantic/structural assertions they already ran.
    case skippedUnsupportedHost(reason: String)
}

/// Runs a single, uniquely-named "victim" `@Test` from this same test target/process in a
/// genuinely separate OS process, under a hard wall-clock deadline.
///
/// This exists specifically to give a performance-regression test real mutation-detection
/// power: a plain in-process timing assertion only *reports* that an operation was slow --
/// it cannot reliably *stop* a still-running, non-cooperatively-cancellable, tight
/// synchronous loop (Swift's structured-concurrency cancellation is cooperative and a loop
/// that never checks `Task.isCancelled` simply keeps consuming a CPU core regardless of any
/// in-process "race" against a timer). Only OS-level process termination genuinely
/// interrupts that work. On timeout this guard sends SIGTERM, allows a short bounded grace,
/// then escalates to SIGKILL and performs a separately bounded reap. Running the victim in
/// a child process whose exact identity remains retained until reap therefore bounds the
/// *test's own* worst-case wall-clock cost even if the victim ignores SIGTERM.
///
/// The child is launched by literally replaying this process's own `CommandLine.arguments`
/// (as captured at the moment this function is called) with only the `--filter` value
/// substituted (or appended, if absent). This is deliberately **not** a re-invocation of
/// `swift test`/`xcodebuild test` from scratch: this test binary is itself already running
/// as a child of exactly such a build+test driver (`swiftpm-testing-helper`, or an
/// Xcode/xcodebuild equivalent), which holds an exclusive lock on the package's build state
/// for the lifetime of that parent invocation. Spawning a *second*, independent top-level
/// `swift test`/`xcodebuild test` against the same package path from within a running test
/// self-deadlocks waiting on that same lock (confirmed empirically: it reliably times out
/// even for a single, otherwise-trivial nested invocation). Replaying
/// `CommandLine.arguments[0...]` re-execs the already-built, already-loaded test host
/// directly -- the same executable and bundle path this very process is already running
/// from -- without going through the build-planning/locking phase at all, so it does not
/// contend with the currently-running parent for that lock.
///
/// That replay strategy is only valid for hosts that actually *have* a `--filter`-shaped
/// argv to replay. `swift test` (and Xcode's SwiftPM-package integration invoking
/// `swiftpm-testing-helper` under the hood) launch this binary with a rich argument list
/// (`--test-bundle-path`, `--package-path`, an optional `--filter`, the `.xctest` path,
/// etc.) that this guard can substitute into. But when the *same* built `.xctest` bundle is
/// instead run via `xcodebuild test`'s own test-selection path against the package's
/// auto-generated Xcode scheme, the host is Apple's classic bare `xctest` agent, launched
/// with **no** CLI arguments at all (`CommandLine.arguments.count == 1`, just the agent's
/// own path) -- test selection there flows entirely through environment/plist state
/// (`XCTestBundlePath`, `XCTestSessionIdentifier`, and/or an `XCTestConfigurationFilePath`
/// plist) that this guard does not attempt to reconstruct. Appending `--filter` to that
/// 1-element argv is silently ignored by the classic `xctest` agent, so the child would run
/// with no test selected at all (or the *entire* bundle) instead of the intended victim --
/// either a false-slow "regression" or a false-fast "pass", neither a truthful signal.
/// ``isSupportedReExecHost(hostArguments:)`` detects this before any subprocess is even
/// attempted, so ``runFiltered(victimFilter:additionalEnvironment:deadlineSeconds:
/// hostArguments:)`` can report an honest, non-fatal skip instead.
enum SubprocessDeadlineGuard {
    /// The environment-variable key under which `runFiltered` tells the launched child
    /// where to write its completion-sentinel file. A victim test must call
    /// ``recordVictimCompletion()`` as the very last step of its body, strictly after all
    /// of its own production assertions have already passed, so the parent can tell a
    /// genuine pass apart from a child that exited 0 without ever doing the intended work
    /// (e.g. a `--filter` that matched zero tests, or the victim's own trigger
    /// environment-variable lookup missing for any reason). Exposed as a single shared
    /// symbol -- rather than a string literal independently retyped at each call site --
    /// specifically so the producer (this file) and every consumer (each victim test) can
    /// never drift into a mismatched key.
    static let completionSentinelEnvironmentKey =
        "SUBPROCESS_DEADLINE_GUARD_COMPLETION_SENTINEL_PATH"

    /// Whether `hostArguments` (normally the current process's own `CommandLine.arguments`)
    /// look like a re-exec-compatible SwiftPM test-driver invocation this guard knows how
    /// to replay with a substituted `--filter`, as opposed to Apple's classic bare `xctest`
    /// agent (the host under `xcodebuild test` against this package's Xcode scheme), which
    /// is launched with no CLI arguments at all. `hostArguments` is an injectable parameter
    /// purely so this predicate is unit-testable without needing an actual second host.
    static func isSupportedReExecHost(hostArguments: [String] = CommandLine.arguments) -> Bool {
        hostArguments.count > 1
    }

    /// Runs the victim test identified by `victimFilter`, under `deadlineSeconds`, with
    /// `additionalEnvironment` merged over this process's own environment (which already
    /// includes anything the outer test invocation was launched with, e.g. `DEVELOPER_DIR`).
    /// `hostArguments` defaults to this process's own `CommandLine.arguments` and is
    /// otherwise only overridden by tests of this guard's own host-detection behavior.
    ///
    /// Returns ``SubprocessDeadlineGuardOutcome/skippedUnsupportedHost(reason:)`` without
    /// launching any subprocess at all if `hostArguments` fails
    /// ``isSupportedReExecHost(hostArguments:)``. Otherwise throws `.timedOut` if the child
    /// is still running once `deadlineSeconds` elapses (it is forcibly terminated first, so
    /// no orphaned CPU-bound work remains); `.childFailed` if the child exited on its own
    /// with a nonzero status (its own `#expect`s failed, or it crashed); or
    /// `.completionUnproven` if the child exited 0 but never wrote the completion-sentinel
    /// file, meaning its intended code path is not proven to have actually executed.
    /// Returns ``SubprocessDeadlineGuardOutcome/completed`` only if the filtered victim
    /// test(s) all passed within the deadline *and* proved they actually ran.
    static func runFiltered(
        victimFilter: String,
        additionalEnvironment: [String: String],
        deadlineSeconds: Double,
        hostArguments: [String] = CommandLine.arguments
    ) throws -> SubprocessDeadlineGuardOutcome {
        guard isSupportedReExecHost(hostArguments: hostArguments) else {
            return .skippedUnsupportedHost(
                reason: unsupportedHostReason(observedArgumentCount: hostArguments.count)
            )
        }

        // A fresh, per-invocation, collision-safe sentinel path: the victim creates this
        // file only after its own real assertions have passed, so a bare zero exit code
        // alone is never treated as sufficient proof of a genuine pass.
        let sentinelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("subprocess-deadline-guard-\(UUID().uuidString).sentinel")
        defer { try? FileManager.default.removeItem(at: sentinelURL) }

        let child = try spawnChild(
            hostArguments: hostArguments,
            victimFilter: victimFilter,
            additionalEnvironment: additionalEnvironment,
            sentinelURL: sentinelURL
        )
        defer { bestEffortCleanup(child) }

        switch try waitWithDeadline(child, deadlineSeconds: deadlineSeconds) {
        case let .timedOut(termination):
            throw SubprocessDeadlineGuardError.timedOut(
                afterSeconds: deadlineSeconds,
                termination: termination
            )
        case let .exited(exit):
            guard exit.exitedNormally, exit.status == 0 else {
                throw SubprocessDeadlineGuardError.childFailed(
                    exitCode: exit.status
                )
            }
        }
        guard FileManager.default.fileExists(atPath: sentinelURL.path) else {
            throw SubprocessDeadlineGuardError.completionUnproven
        }
        return .completed
    }

    /// The explanatory reason attached to a ``SubprocessDeadlineGuardOutcome/
    /// skippedUnsupportedHost(reason:)`` outcome, given how many launch arguments were
    /// actually observed. Split out purely to keep `runFiltered` itself short.
    private static func unsupportedHostReason(observedArgumentCount: Int) -> String {
        "the current process's launch arguments provide no re-exec-compatible \"--filter\" " +
            "slot (\(observedArgumentCount) argument(s) observed); this is the fingerprint " +
            "of Xcode's bare xctest bundle-injection host (e.g. running this package's " +
            "tests via its auto-generated Xcode scheme under `xcodebuild test`), which " +
            "selects tests via XCTestBundlePath/XCTestConfigurationFilePath environment " +
            "state rather than CLI arguments, and this guard has no verified way to " +
            "reconstruct or replay that selection"
    }

    /// Call this as the very last step of a victim test's body, strictly after all of its
    /// own production assertions have already passed, to prove to the parent
    /// `runFiltered` invocation that this process's intended work genuinely executed
    /// (rather than returning early -- e.g. because its own trigger environment-variable
    /// lookup missed for any reason). A no-op if the sentinel key is absent, which is
    /// exactly what happens when this victim is instead discovered and run directly by the
    /// full test suite outside of `runFiltered` (its usual, harmless, instant no-op path).
    static func recordVictimCompletion() {
        guard let path = ProcessInfo.processInfo.environment[completionSentinelEnvironmentKey]
        else {
            return
        }
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    /// Returns `arguments` with its `--filter` value replaced by `victimFilter`. If
    /// `arguments` has no `--filter` at all, a new trailing `--filter victimFilter` pair is
    /// appended. If `arguments` ends in an unpaired trailing `--filter` (no following
    /// value), only the missing value is appended -- pairing it with that existing flag --
    /// rather than appending a *second* `--filter` flag, which would otherwise corrupt the
    /// invocation into `... --filter --filter victimFilter` (a dangling, unpaired flag
    /// immediately followed by another flag+value, which a filter-argument parser could
    /// easily misinterpret).
    static func replacingFilterArgument(
        in arguments: [String],
        with victimFilter: String
    ) -> [String] {
        guard let filterFlagIndex = arguments.firstIndex(of: "--filter") else {
            return arguments + ["--filter", victimFilter]
        }
        let valueIndex = filterFlagIndex + 1
        guard arguments.indices.contains(valueIndex) else {
            return arguments + [victimFilter]
        }
        var replaced = arguments
        replaced[valueIndex] = victimFilter
        return replaced
    }
}
