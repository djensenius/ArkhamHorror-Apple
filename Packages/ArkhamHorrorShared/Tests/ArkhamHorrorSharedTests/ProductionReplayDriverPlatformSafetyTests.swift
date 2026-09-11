import Darwin
import Foundation
import Testing

private enum ReplayDriverFIFOTestEnvironmentKey {
    static let trigger = "ARKHAM_PRODUCTION_REPLAY_FIFO_READ_SELFTEST"
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
