import Darwin
import Foundation

struct SubprocessDeadlineObservedExit {
    let status: Int32
    let exitedNormally: Bool
}

enum SubprocessDeadlineWaitResult {
    case exited(SubprocessDeadlineObservedExit)
    case timedOut(SubprocessDeadlineTermination)
}

final class SubprocessDeadlineChild {
    let pid: pid_t
    let processGroupID: pid_t
    var observedExit: SubprocessDeadlineObservedExit?
    var isReaped = false

    init(pid: pid_t, processGroupID: pid_t) {
        self.pid = pid
        self.processGroupID = processGroupID
    }
}

extension SubprocessDeadlineGuard {
    static let terminationGraceSeconds = 0.5
    static let killObservationSeconds = 1.0
    static let reapTimeoutSeconds = 0.25
    static let emergencyCleanupSeconds = 0.25
    static let maximumTerminationOverheadSeconds =
        terminationGraceSeconds +
        killObservationSeconds +
        reapTimeoutSeconds +
        emergencyCleanupSeconds

    private static let pollIntervalSeconds = 0.01

    static func spawnChild(
        hostArguments: [String],
        victimFilter: String,
        additionalEnvironment: [String: String],
        sentinelURL: URL
    ) throws -> SubprocessDeadlineChild {
        let childArguments = replacingFilterArgument(
            in: Array(hostArguments.dropFirst()),
            with: victimFilter
        )
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in additionalEnvironment {
            environment[key] = value
        }
        environment[completionSentinelEnvironmentKey] = sentinelURL.path

        let arguments = [hostArguments[0]] + childArguments
        let environmentEntries = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        return try spawnExecutable(
            executablePath: hostArguments[0],
            arguments: arguments,
            environmentEntries: environmentEntries
        )
    }

    static func spawnExecutable(
        executablePath: String,
        arguments: [String],
        environmentEntries: [String],
        afterSpawn: (pid_t) throws -> Void = { _ in }
    ) throws -> SubprocessDeadlineChild {
        try withCStringArray(arguments) { argumentPointer in
            try withCStringArray(environmentEntries) { environmentPointer in
                try spawnConfiguredChild(
                    executablePath: executablePath,
                    argumentPointer: argumentPointer,
                    environmentPointer: environmentPointer,
                    afterSpawn: afterSpawn
                )
            }
        }
    }

    static func waitWithDeadline(
        _ child: SubprocessDeadlineChild,
        deadlineSeconds: Double
    ) throws -> SubprocessDeadlineWaitResult {
        let deadline = ContinuousClock.now + .seconds(deadlineSeconds)
        if let exit = try observeExit(of: child, until: deadline) {
            try terminateSurvivingDescendants(of: child)
            try reap(child)
            return .exited(exit)
        }

        let termination = try terminateProcessGroup(child)
        try reap(child)
        return .timedOut(termination)
    }

    static func bestEffortCleanup(_ child: SubprocessDeadlineChild) {
        guard !child.isReaped else { return }
        _ = kill(-child.processGroupID, SIGKILL)
        _ = kill(child.pid, SIGKILL)
        let deadline = ContinuousClock.now +
            .seconds(emergencyCleanupSeconds)
        while true {
            if (try? processGroupHasMembersOtherThanLeader(child)) == false {
                var status: Int32 = 0
                let result = waitpid(child.pid, &status, WNOHANG)
                if result == child.pid || (result < 0 && errno == ECHILD) {
                    child.isReaped = true
                    return
                }
                if result < 0, errno != EINTR {
                    return
                }
            }
            guard ContinuousClock.now < deadline else { return }
            Thread.sleep(forTimeInterval: pollIntervalSeconds)
        }
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        body: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) throws -> Result
    ) throws -> Result {
        guard strings.allSatisfy({ !$0.contains("\0") }) else {
            throw SubprocessDeadlineGuardError.launchFailed(code: EINVAL)
        }
        var storage: [UnsafeMutablePointer<CChar>] = []
        defer { storage.forEach { free($0) } }
        for string in strings {
            guard let pointer = strdup(string) else {
                throw SubprocessDeadlineGuardError.launchFailed(code: ENOMEM)
            }
            storage.append(pointer)
        }
        var pointers: [UnsafeMutablePointer<CChar>?] =
            storage.map(Optional.some) + [nil]
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw SubprocessDeadlineGuardError.launchFailed(code: EINVAL)
            }
            return try body(baseAddress)
        }
    }

    private static func observeExit(
        of child: SubprocessDeadlineChild,
        until deadline: ContinuousClock.Instant
    ) throws -> SubprocessDeadlineObservedExit? {
        while true {
            if let exit = try observeExitIfPresent(of: child) {
                return exit
            }
            guard ContinuousClock.now < deadline else { return nil }
            Thread.sleep(forTimeInterval: pollIntervalSeconds)
        }
    }

    private static func observeExitIfPresent(
        of child: SubprocessDeadlineChild
    ) throws -> SubprocessDeadlineObservedExit? {
        if let observedExit = child.observedExit {
            return observedExit
        }
        while true {
            var info = siginfo_t()
            // Keep the leader waitable so its PID/PGID cannot be reused before cleanup.
            let result = waitid(
                P_PID,
                id_t(child.pid),
                &info,
                WEXITED | WNOHANG | WNOWAIT
            )
            if result == 0 {
                guard info.si_pid != 0 else { return nil }
                let exit = SubprocessDeadlineObservedExit(
                    status: info.si_status,
                    exitedNormally: info.si_code == CLD_EXITED
                )
                child.observedExit = exit
                return exit
            }
            if errno == EINTR {
                continue
            }
            throw SubprocessDeadlineGuardError.waitFailed(code: errno)
        }
    }

    private static func observeTerminatedProcessGroup(
        _ child: SubprocessDeadlineChild,
        until deadline: ContinuousClock.Instant
    ) throws -> Bool {
        while true {
            let childExited = try observeExitIfPresent(of: child) != nil
            let hasDescendants = try processGroupHasMembersOtherThanLeader(
                child
            )
            if childExited, !hasDescendants {
                return true
            }
            guard ContinuousClock.now < deadline else { return false }
            Thread.sleep(forTimeInterval: pollIntervalSeconds)
        }
    }

    private static func terminateSurvivingDescendants(
        of child: SubprocessDeadlineChild
    ) throws {
        guard try processGroupHasMembersOtherThanLeader(child) else { return }
        _ = try terminateProcessGroup(child)
    }

    private static func terminateProcessGroup(
        _ child: SubprocessDeadlineChild
    ) throws -> SubprocessDeadlineTermination {
        try sendSignal(SIGTERM, to: child)
        let graceDeadline = ContinuousClock.now +
            .seconds(terminationGraceSeconds)
        if try observeTerminatedProcessGroup(
            child,
            until: graceDeadline
        ) {
            return .exitedDuringGrace
        }

        try sendSignal(SIGKILL, to: child)
        let killDeadline = ContinuousClock.now +
            .seconds(killObservationSeconds)
        guard try observeTerminatedProcessGroup(
            child,
            until: killDeadline
        ) else {
            throw SubprocessDeadlineGuardError.terminationUnconfirmed(
                pid: child.pid
            )
        }
        return .killedAfterGrace
    }

    private static func processGroupHasMembersOtherThanLeader(
        _ child: SubprocessDeadlineChild
    ) throws -> Bool {
        let requiredBytes = proc_listpgrppids(
            child.processGroupID,
            nil,
            0
        )
        guard requiredBytes >= 0 else {
            throw SubprocessDeadlineGuardError.waitFailed(code: errno)
        }
        let capacity = max(
            1,
            Int(requiredBytes) / MemoryLayout<pid_t>.stride + 8
        )
        var processIdentifiers = [pid_t](repeating: 0, count: capacity)
        let count = processIdentifiers.withUnsafeMutableBytes { buffer in
            proc_listpgrppids(
                child.processGroupID,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard count >= 0 else {
            throw SubprocessDeadlineGuardError.waitFailed(code: errno)
        }
        // The retained leader is expected here; only another member keeps the group alive.
        let listedCount = min(Int(count), processIdentifiers.count)
        if processIdentifiers.prefix(listedCount).contains(where: {
            $0 > 0 && $0 != child.pid
        }) {
            return true
        }
        return Int(count) >= processIdentifiers.count
    }

    private static func sendSignal(
        _ signal: Int32,
        to child: SubprocessDeadlineChild
    ) throws {
        guard kill(-child.processGroupID, signal) == 0 || errno == ESRCH else {
            throw SubprocessDeadlineGuardError.signalFailed(
                signal: signal,
                code: errno
            )
        }
    }

    private static func reap(_ child: SubprocessDeadlineChild) throws {
        guard !child.isReaped else { return }
        let deadline = ContinuousClock.now + .seconds(reapTimeoutSeconds)
        while true {
            var status: Int32 = 0
            let result = waitpid(child.pid, &status, WNOHANG)
            if result == child.pid {
                child.isReaped = true
                return
            }
            if result < 0, errno == EINTR {
                continue
            }
            if result < 0 {
                throw SubprocessDeadlineGuardError.waitFailed(code: errno)
            }
            guard ContinuousClock.now < deadline else {
                throw SubprocessDeadlineGuardError.reapTimedOut(
                    pid: child.pid,
                    afterSeconds: reapTimeoutSeconds
                )
            }
            Thread.sleep(forTimeInterval: pollIntervalSeconds)
        }
    }
}
