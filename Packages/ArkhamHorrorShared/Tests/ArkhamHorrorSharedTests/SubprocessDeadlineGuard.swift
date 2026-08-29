import Foundation

/// Errors surfaced by ``SubprocessDeadlineGuard``.
enum SubprocessDeadlineGuardError: Error, CustomStringConvertible {
    case timedOut(afterSeconds: Double)
    case childFailed(exitCode: Int32)
    case noFilterArgument

    var description: String {
        switch self {
        case let .timedOut(afterSeconds):
            "Subprocess exceeded the \(afterSeconds)s deadline and was forcibly terminated. " +
                "This is the expected failure mode for a reintroduced quadratic-time " +
                "normalization loop -- the fixed (linear) implementation must comfortably " +
                "finish within this deadline."
        case let .childFailed(exitCode):
            "Subprocess's own test assertions failed or it crashed (exit code \(exitCode))."
        case .noFilterArgument:
            "CommandLine.arguments was empty; this guard only knows how to re-invoke the " +
                "current test run's own launch command with a substituted/added filter."
        }
    }
}

/// Runs a single, uniquely-named "victim" `@Test` from this same test target/process in a
/// genuinely separate OS process, under a hard wall-clock deadline.
///
/// This exists specifically to give a performance-regression test real mutation-detection
/// power: a plain in-process timing assertion only *reports* that an operation was slow --
/// it cannot reliably *stop* a still-running, non-cooperatively-cancellable, tight
/// synchronous loop (Swift's structured-concurrency cancellation is cooperative and a loop
/// that never checks `Task.isCancelled` simply keeps consuming a CPU core regardless of any
/// in-process "race" against a timer). Only OS-level process termination (`SIGTERM`, whose
/// default disposition is to end the process immediately, even mid-loop) genuinely
/// interrupts that work. Running the victim in a child process we can kill also bounds the
/// *test's own* worst-case wall-clock cost to the configured deadline, regardless of how
/// pathologically slow a reintroduced quadratic (or worse) implementation would actually be
/// at the chosen input size.
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
enum SubprocessDeadlineGuard {
    /// Runs the victim test identified by `victimFilter`, under `deadlineSeconds`, with
    /// `additionalEnvironment` merged over this process's own environment (which already
    /// includes anything the outer test invocation was launched with, e.g. `DEVELOPER_DIR`).
    ///
    /// Throws `.timedOut` if the child is still running once `deadlineSeconds` elapses (it
    /// is forcibly terminated first, so no orphaned CPU-bound work remains), or
    /// `.childFailed` if the child exited on its own with a nonzero status (its own
    /// `#expect`s failed, or it crashed). Returns normally only if the filtered victim
    /// test(s) all passed within the deadline.
    static func runFiltered(
        victimFilter: String,
        additionalEnvironment: [String: String],
        deadlineSeconds: Double
    ) throws {
        let launchArguments = CommandLine.arguments
        guard !launchArguments.isEmpty else {
            throw SubprocessDeadlineGuardError.noFilterArgument
        }

        let childArguments = replacingFilterArgument(
            in: Array(launchArguments.dropFirst()),
            with: victimFilter
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchArguments[0])
        process.arguments = childArguments

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in additionalEnvironment {
            environment[key] = value
        }
        process.environment = environment

        // Only the exit status matters here; discarding output avoids any risk of this
        // process blocking on a full pipe buffer while we are busy polling for the deadline
        // below (a pipe we never drained could otherwise deadlock the child).
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        let deadline = Date().addingTimeInterval(deadlineSeconds)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()

        if timedOut {
            throw SubprocessDeadlineGuardError.timedOut(afterSeconds: deadlineSeconds)
        }
        guard process.terminationStatus == 0 else {
            throw SubprocessDeadlineGuardError.childFailed(exitCode: process.terminationStatus)
        }
    }

    /// Returns `arguments` with its `--filter` value replaced by `victimFilter`, or with a
    /// new trailing `--filter victimFilter` appended if `arguments` has none (or an
    /// unpaired trailing `--filter` with no following value).
    private static func replacingFilterArgument(
        in arguments: [String],
        with victimFilter: String
    ) -> [String] {
        guard let filterFlagIndex = arguments.firstIndex(of: "--filter") else {
            return arguments + ["--filter", victimFilter]
        }
        let valueIndex = filterFlagIndex + 1
        guard arguments.indices.contains(valueIndex) else {
            return arguments + ["--filter", victimFilter]
        }
        var replaced = arguments
        replaced[valueIndex] = victimFilter
        return replaced
    }
}
