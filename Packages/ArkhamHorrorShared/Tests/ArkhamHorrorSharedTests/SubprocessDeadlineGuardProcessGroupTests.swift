import Darwin
import Foundation
import Testing

private enum ProcessGroupVictimEnvironmentKey {
    static let mode = "SUBPROCESS_DEADLINE_GUARD_PROCESS_GROUP_MODE"
    static let descendantRecordPath =
        "SUBPROCESS_DEADLINE_GUARD_DESCENDANT_RECORD_PATH"
}

private enum ProcessGroupVictimMode: String {
    case succeed
    case fail
}

private enum ProcessGroupTestError: Error {
    case spawnFailed(code: Int32)
    case waitFailed(code: Int32)
    case fastExitNotObserved(pid: pid_t)
    case missingDescendantRecordPath
    case descendantRecordWriteFailed
    case malformedDescendantRecord
    case processListFailed(code: Int32)
}

private struct ProcessGroupDescendantRecord {
    let processGroupID: pid_t
    let descendantPID: pid_t
}

@Test("Process-group cleanup victim (subprocess-only)")
func subprocessDeadlineGuardProcessGroupExitVictim() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let rawMode = environment[ProcessGroupVictimEnvironmentKey.mode],
          let mode = ProcessGroupVictimMode(rawValue: rawMode)
    else {
        return
    }
    guard let recordPath = environment[
        ProcessGroupVictimEnvironmentKey.descendantRecordPath
    ] else {
        throw ProcessGroupTestError.missingDescendantRecordPath
    }

    let descendantPID = try spawnSIGTERMResistantDescendant(
        environment: environment
    )
    let record = "\(getpgrp()) \(descendantPID)"
    guard FileManager.default.createFile(
        atPath: recordPath,
        contents: Data(record.utf8)
    ) else {
        throw ProcessGroupTestError.descendantRecordWriteFailed
    }

    switch mode {
    case .succeed:
        SubprocessDeadlineGuard.recordVictimCompletion()
    case .fail:
        #expect(
            Bool(false),
            "Intentional failure after spawning a process-group descendant."
        )
    }
}

private func spawnSIGTERMResistantDescendant(
    environment: [String: String]
) throws -> pid_t {
    // An ignored disposition survives exec, making /bin/sleep deterministic proof that
    // cleanup escalates past SIGTERM after this leader returns.
    _ = signal(SIGTERM, SIG_IGN)
    var descendantPID: pid_t = 0
    let environmentEntries = environment
        .map { "\($0.key)=\($0.value)" }
        .sorted()
    try withProcessGroupTestCStringArray(
        ["/bin/sleep", "60"]
    ) { argumentPointer in
        try withProcessGroupTestCStringArray(
            environmentEntries
        ) { environmentPointer in
            let result = posix_spawn(
                &descendantPID,
                "/bin/sleep",
                nil,
                nil,
                argumentPointer,
                environmentPointer
            )
            guard result == 0 else {
                throw ProcessGroupTestError.spawnFailed(code: result)
            }
        }
    }
    return descendantPID
}

private func withProcessGroupTestCStringArray<Result>(
    _ strings: [String],
    body: (
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    ) throws -> Result
) throws -> Result {
    var storage: [UnsafeMutablePointer<CChar>] = []
    defer { storage.forEach { free($0) } }
    for string in strings {
        guard let pointer = strdup(string) else {
            throw ProcessGroupTestError.spawnFailed(code: ENOMEM)
        }
        storage.append(pointer)
    }
    var pointers: [UnsafeMutablePointer<CChar>?] =
        storage.map(Optional.some) + [nil]
    return try pointers.withUnsafeMutableBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            throw ProcessGroupTestError.spawnFailed(code: EINVAL)
        }
        return try body(baseAddress)
    }
}

private func waitForExitedChildWithoutReaping(_ pid: pid_t) throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while true {
        var info = siginfo_t()
        let result = waitid(
            P_PID,
            id_t(pid),
            &info,
            WEXITED | WNOHANG | WNOWAIT
        )
        if result == 0, info.si_pid == pid {
            return
        }
        if result < 0, errno != EINTR {
            throw ProcessGroupTestError.waitFailed(code: errno)
        }
        guard ContinuousClock.now < deadline else {
            throw ProcessGroupTestError.fastExitNotObserved(pid: pid)
        }
        Thread.sleep(forTimeInterval: 0.001)
    }
}

private func readProcessGroupDescendantRecord(
    at url: URL
) throws -> ProcessGroupDescendantRecord {
    let fields = try String(contentsOf: url, encoding: .utf8)
        .split(separator: " ")
    guard fields.count == 2,
          let processGroupID = pid_t(fields[0]),
          let descendantPID = pid_t(fields[1])
    else {
        throw ProcessGroupTestError.malformedDescendantRecord
    }
    return ProcessGroupDescendantRecord(
        processGroupID: processGroupID,
        descendantPID: descendantPID
    )
}

private func processGroupMembers(
    processGroupID: pid_t
) throws -> [pid_t] {
    let requiredBytes = proc_listpgrppids(processGroupID, nil, 0)
    guard requiredBytes >= 0 else {
        throw ProcessGroupTestError.processListFailed(code: errno)
    }
    let capacity = max(
        1,
        Int(requiredBytes) / MemoryLayout<pid_t>.stride + 8
    )
    var processIdentifiers = [pid_t](repeating: 0, count: capacity)
    let count = processIdentifiers.withUnsafeMutableBytes { buffer in
        proc_listpgrppids(
            processGroupID,
            buffer.baseAddress,
            Int32(buffer.count)
        )
    }
    guard count >= 0 else {
        throw ProcessGroupTestError.processListFailed(code: errno)
    }
    return Array(
        processIdentifiers
            .prefix(min(Int(count), processIdentifiers.count))
            .filter { $0 > 0 }
    )
}

@Suite("SubprocessDeadlineGuard process groups")
struct SubprocessDeadlineGuardProcessGroupTests {
    private func recordSkippedHostWarning(_ reason: String) {
        Issue.record(
            Comment(rawValue: "Skipped subprocess process-group regression: \(reason)"),
            severity: .warning
        )
    }

    private func expectNoRecordedProcessGroupMembers(at recordURL: URL) throws {
        let record = try readProcessGroupDescendantRecord(at: recordURL)
        #expect(
            try processGroupMembers(
                processGroupID: record.processGroupID
            ).isEmpty
        )

        errno = 0
        let descendantProbe = kill(record.descendantPID, 0)
        let descendantProbeError = errno
        #expect(descendantProbe == -1)
        #expect(descendantProbeError == ESRCH)

        errno = 0
        let groupProbe = kill(-record.processGroupID, 0)
        let groupProbeError = errno
        #expect(groupProbe == -1)
        #expect(groupProbeError == ESRCH)
    }

    @Test("A successful leader cannot leak a SIGTERM-resistant descendant")
    func successfulLeaderCleansSurvivingDescendant() throws {
        let recordURL = makeDescendantRecordURL()
        defer { try? FileManager.default.removeItem(at: recordURL) }

        let outcome = try SubprocessDeadlineGuard.runFiltered(
            victimFilter: "subprocessDeadlineGuardProcessGroupExitVictim",
            additionalEnvironment: descendantEnvironment(
                mode: .succeed,
                recordURL: recordURL
            ),
            deadlineSeconds: 20
        )
        if case let .skippedUnsupportedHost(reason) = outcome {
            recordSkippedHostWarning(reason)
            return
        }

        #expect(outcome == .completed)
        try expectNoRecordedProcessGroupMembers(at: recordURL)
    }

    @Test("A failed leader cannot leak a SIGTERM-resistant descendant")
    func failedLeaderCleansSurvivingDescendant() throws {
        let recordURL = makeDescendantRecordURL()
        defer { try? FileManager.default.removeItem(at: recordURL) }

        do {
            let outcome = try SubprocessDeadlineGuard.runFiltered(
                victimFilter: "subprocessDeadlineGuardProcessGroupExitVictim",
                additionalEnvironment: descendantEnvironment(
                    mode: .fail,
                    recordURL: recordURL
                ),
                deadlineSeconds: 20
            )
            if case let .skippedUnsupportedHost(reason) = outcome {
                recordSkippedHostWarning(reason)
                return
            }
            Issue.record("Expected .childFailed, got \(outcome) instead.")
        } catch let error as SubprocessDeadlineGuardError {
            guard case .childFailed = error else {
                Issue.record("Expected .childFailed, got \(error) instead.")
                return
            }
        }

        try expectNoRecordedProcessGroupMembers(at: recordURL)
    }

    @Test("A child exiting before post-spawn inspection is a normal exit")
    func fastExitAfterSpawnIsNotLaunchFailure() throws {
        let environmentEntries = ProcessInfo.processInfo.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let child = try SubprocessDeadlineGuard.spawnExecutable(
            executablePath: "/usr/bin/true",
            arguments: ["/usr/bin/true"],
            environmentEntries: environmentEntries,
            afterSpawn: waitForExitedChildWithoutReaping
        )
        defer { SubprocessDeadlineGuard.bestEffortCleanup(child) }

        let result = try SubprocessDeadlineGuard.waitWithDeadline(
            child,
            deadlineSeconds: 1
        )
        guard case let .exited(exit) = result else {
            Issue.record("Expected a normal fast exit, got \(result) instead.")
            return
        }
        #expect(exit.exitedNormally)
        #expect(exit.status == 0)
    }

    private func makeDescendantRecordURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "subprocess-deadline-descendant-\(UUID().uuidString)"
            )
    }

    private func descendantEnvironment(
        mode: ProcessGroupVictimMode,
        recordURL: URL
    ) -> [String: String] {
        [
            ProcessGroupVictimEnvironmentKey.mode: mode.rawValue,
            ProcessGroupVictimEnvironmentKey.descendantRecordPath:
                recordURL.path,
        ]
    }
}
