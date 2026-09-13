import Darwin
import Foundation
import Testing

private enum ReplayDriverFIFOTestEnvironmentKey {
    static let trigger = "ARKHAM_PRODUCTION_REPLAY_FIFO_READ_SELFTEST"
}

private enum ReplayTerminationEnvironmentKey {
    static let mode = "ARKHAM_PRODUCTION_REPLAY_TERMINATION_SELFTEST"
    static let readyPath = "ARKHAM_PRODUCTION_REPLAY_TERMINATION_READY_PATH"
}

private func replayTemporaryDirectoryThroughVarAlias() -> URL {
    let temporaryDirectory = FileManager.default.temporaryDirectory
    let physicalPrefix = "/private/var"
    guard temporaryDirectory.path == physicalPrefix ||
        temporaryDirectory.path.hasPrefix(physicalPrefix + "/")
    else {
        return temporaryDirectory
    }
    return URL(
        fileURLWithPath: "/var" + String(
            temporaryDirectory.path.dropFirst(physicalPrefix.count)
        ),
        isDirectory: true
    )
}

private func runSuccessfulReplay(
    to resultURL: URL,
    data: Data
) throws -> ProductionReplayRunResult {
    try ProductionReplayDriver.run(
        victim: makeVictim(),
        input: makeInput(resultURL: resultURL),
        deadlineSeconds: 1,
        deadlineRunner: { _, environment, _, _ in
            let staging = try URL(fileURLWithPath: #require(
                environment[ProductionReplayEnvironmentKey.resultPath]
            ))
            try data.write(to: staging)
            return .completed
        }
    )
}

private func makeResistantReplay(
    resultURL: URL,
    readyURL: URL
) throws -> (
    victim: ProductionReplayVictim,
    input: ProductionReplayInput<ReplayDriverSelfTestCheckpoint>
) {
    let input = try ProductionReplayInput(
        checkpoint: ReplayDriverSelfTestCheckpoint.assignmentContinuation,
        resultURL: resultURL,
        additionalEnvironment: [
            ReplayTerminationEnvironmentKey.mode: "ignore-sigterm",
            ReplayTerminationEnvironmentKey.readyPath: readyURL.path,
        ]
    )
    let victim = try ProductionReplayVictim(
        moduleName: "ArkhamHorrorSharedTests",
        suiteName: "ReplayDriverTerminationVictimSuite",
        functionName: "productionReplayIgnoringSIGTERMVictim"
    )
    return (victim, input)
}

@Suite("Production replay FIFO victim")
struct ReplayDriverFIFOVictimSuite {
    @Test("Post-publication FIFO substitution is nonblocking")
    func productionReplayFIFOReadVictim() throws {
        guard ProcessInfo.processInfo.environment[
            ReplayDriverFIFOTestEnvironmentKey.trigger
        ] == "1" else {
            return
        }
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let result = try runSuccessfulReplay(
            to: scratch.result,
            data: Data("published".utf8)
        )
        try FileManager.default.removeItem(at: scratch.result)
        try #require(mkfifo(scratch.result.path, 0o600) == 0)

        #expect(throws: ProductionReplayDriverError.resultMissingOrNotRegular) {
            _ = try result.resultData()
        }
        SubprocessDeadlineGuard.recordVictimCompletion()
    }
}

@Suite("Production replay termination victim")
struct ReplayDriverTerminationVictimSuite {
    @Test("SIGTERM-resistant replay victim")
    func productionReplayIgnoringSIGTERMVictim() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[ReplayTerminationEnvironmentKey.mode] ==
            "ignore-sigterm"
        else {
            return
        }
        _ = signal(SIGTERM, SIG_IGN)
        let context =
            try ProductionReplayChildContext<ReplayDriverSelfTestCheckpoint>(
                environment: environment
            )
        try Data("untrusted".utf8).write(to: context.resultURL)
        let readyPath = try #require(
            environment[ReplayTerminationEnvironmentKey.readyPath]
        )
        try Data().write(to: URL(fileURLWithPath: readyPath))
        while true {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

@Suite("Production replay driver read safety")
struct ReplayDriverReadSafetyTests {
    @Test("Published FIFO substitution fails within the subprocess deadline")
    func publishedFIFOSubstitutionFailsPromptly() throws {
        let victim = try ProductionReplayVictim(
            moduleName: "ArkhamHorrorSharedTests",
            suiteName: "ReplayDriverFIFOVictimSuite",
            functionName: "productionReplayFIFOReadVictim"
        )
        let outcome = try SubprocessDeadlineGuard.runFiltered(
            victimFilter: victim.exactFilter,
            additionalEnvironment: [
                ReplayDriverFIFOTestEnvironmentKey.trigger: "1",
            ],
            deadlineSeconds: 2,
            hostArguments: CommandLine.arguments
        )
        if case let .skippedUnsupportedHost(reason) = outcome {
            Issue.record(
                Comment(
                    rawValue: "Skipped replay FIFO subprocess regression: \(reason)"
                ),
                severity: .warning
            )
            return
        }
        #expect(outcome == .completed)
    }
}

@Suite("Production replay driver termination safety")
struct ReplayDriverTerminationSafetyTests {
    @Test("SIGTERM-resistant child is killed and staging cleanup remains bounded")
    func resistantChildIsKilledAndStagingIsRemoved() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        try Data("stable".utf8).write(to: scratch.result)
        let readyURL = scratch.directory.appendingPathComponent("child-ready")
        let replay = try makeResistantReplay(
            resultURL: scratch.result,
            readyURL: readyURL
        )
        let deadlineSeconds = 2.0
        let startedAt = Date()

        do {
            let result = try ProductionReplayDriver.run(
                victim: replay.victim,
                input: replay.input,
                deadlineSeconds: deadlineSeconds
            )
            if case let .skippedUnsupportedHost(reason) = result.outcome {
                Issue.record(
                    Comment(rawValue: "Skipped replay termination test: \(reason)"),
                    severity: .warning
                )
                return
            }
            Issue.record("Expected the resistant replay child to time out.")
        } catch let error as SubprocessDeadlineGuardError {
            guard case let .timedOut(observedDeadline, termination) = error else {
                Issue.record("Expected .timedOut, got \(error) instead.")
                return
            }
            #expect(observedDeadline == deadlineSeconds)
            #expect(termination == .killedAfterGrace)
        }

        #expect(
            Date().timeIntervalSince(startedAt) <
                deadlineSeconds +
                SubprocessDeadlineGuard.maximumTerminationOverheadSeconds +
                1
        )
        #expect(FileManager.default.fileExists(atPath: readyURL.path))
        #expect(try Data(contentsOf: scratch.result) == Data("stable".utf8))
        #expect(try stagingArtifacts(in: scratch.directory).isEmpty)
    }
}

@Suite("Production replay driver platform paths")
struct ReplayDriverPlatformPathTests {
    @Test("Trusted tmp alias permits a caller-owned mkdtemp destination")
    func tmpAliasPermitsCallerOwnedDestination() throws {
        var template = Array(
            "/tmp/production-replay-mkdtemp-XXXXXX".utf8CString
        )
        let createdPath: String? = template.withUnsafeMutableBufferPointer {
            guard let baseAddress = $0.baseAddress,
                  let created = mkdtemp(baseAddress)
            else {
                return nil
            }
            return String(cString: created)
        }
        let path = try #require(createdPath)
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        var directoryInfo = stat()
        try #require(lstat(directory.path, &directoryInfo) == 0)
        #expect(directoryInfo.st_uid == geteuid())
        #expect(directoryInfo.st_mode & 0o777 == 0o700)
        let resultURL = directory.appendingPathComponent("result.json")
        let result = try runSuccessfulReplay(
            to: resultURL,
            data: Data("tmp".utf8)
        )
        #expect(try result.resultData() == Data("tmp".utf8))

        let target = directory.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        let link = directory.appendingPathComponent("attacker-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )
        #expect(throws: ProductionReplayDriverError.invalidResultParent) {
            _ = try makeInput(
                resultURL: link.appendingPathComponent("result.json")
            )
        }
    }

    @Test("Canonical private tmp permits a caller-owned destination")
    func canonicalPrivateTmpPermitsCallerOwnedDestination() throws {
        var template = Array(
            "/private/tmp/production-replay-mkdtemp-XXXXXX".utf8CString
        )
        let createdPath: String? = template.withUnsafeMutableBufferPointer {
            guard let baseAddress = $0.baseAddress,
                  let created = mkdtemp(baseAddress)
            else {
                return nil
            }
            return String(cString: created)
        }
        let path = try #require(createdPath)
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let result = try runSuccessfulReplay(
            to: directory.appendingPathComponent("result.json"),
            data: Data("private-tmp".utf8)
        )
        #expect(try result.resultData() == Data("private-tmp".utf8))
    }

    @Test("Platform temporary paths work while nested symlinks still fail")
    func temporaryDirectoryAliasIsNarrowlyCanonicalized() throws {
        let directory = replayTemporaryDirectoryThroughVarAlias()
            .appendingPathComponent(
                "production-replay-alias-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let resultURL = directory.appendingPathComponent("result.json")
        let result = try runSuccessfulReplay(
            to: resultURL,
            data: Data("temporary".utf8)
        )
        #expect(try result.resultData() == Data("temporary".utf8))

        let target = directory.appendingPathComponent(
            "target",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        let link = directory.appendingPathComponent("attacker-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )
        #expect(throws: ProductionReplayDriverError.invalidResultParent) {
            _ = try makeInput(
                resultURL: link.appendingPathComponent("nested/result.json")
            )
        }
    }
}
