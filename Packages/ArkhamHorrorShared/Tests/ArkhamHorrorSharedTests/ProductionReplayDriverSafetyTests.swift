import Darwin
import Foundation
import Testing

private enum ReplayDriverSafetyTestError: Error {
    case assertionFailed
}

@Suite("Production replay driver safety")
struct ProductionReplayDriverSafetyTests {
    @Test("Directory, symlink, special-file, and unsafe-parent destinations are untouched")
    func destructiveResultPathsAreRejected() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        try expectDirectoryDestinationRejected(scratch.directory)
        try expectSymlinkDestinationRejected(scratch.directory)
        try expectSpecialDestinationRejected(scratch.directory)
        try expectUnsafeParentsRejected(scratch.directory)
    }

    private func expectDirectoryDestinationRejected(_ directory: URL) throws {
        let marker = directory.appendingPathComponent("marker")
        try Data("keep".utf8).write(to: marker)
        #expect(throws: ProductionReplayDriverError.self) {
            _ = try makeInput(resultURL: directory)
        }
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    }

    private func expectSymlinkDestinationRejected(_ directory: URL) throws {
        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent("result-link")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: target.path
        )
        #expect(throws: ProductionReplayDriverError.self) {
            _ = try makeInput(resultURL: link)
        }
        #expect(try Data(contentsOf: target) == Data("target".utf8))
    }

    private func expectSpecialDestinationRejected(_ directory: URL) throws {
        let fifo = directory.appendingPathComponent("result-fifo")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: ProductionReplayDriverError.self) {
            _ = try makeInput(resultURL: fifo)
        }
    }

    private func expectUnsafeParentsRejected(_ directory: URL) throws {
        let unsafeParent = directory.appendingPathComponent(
            "unsafe",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unsafeParent,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: unsafeParent.path
        )
        #expect(throws: ProductionReplayDriverError.self) {
            _ = try makeInput(
                resultURL: unsafeParent.appendingPathComponent("result.json")
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: unsafeParent.path
        )

        let realParent = directory.appendingPathComponent(
            "real-parent",
            isDirectory: true
        )
        let parentLink = directory.appendingPathComponent(
            "parent-link",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realParent,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            atPath: parentLink.path,
            withDestinationPath: realParent.path
        )
        #expect(throws: ProductionReplayDriverError.self) {
            _ = try makeInput(
                resultURL: parentLink.appendingPathComponent("result.json")
            )
        }
    }

    @Test("Failed and skipped children never publish or retain staging artifacts")
    func failedAndSkippedChildrenDiscardStaging() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        try Data("trusted".utf8).write(to: scratch.result)
        let victim = try makeVictim()
        let input = try makeInput(resultURL: scratch.result)
        var failedStaging: URL?

        #expect(throws: SubprocessDeadlineGuardError.self) {
            _ = try ProductionReplayDriver.run(
                victim: victim,
                input: input,
                deadlineSeconds: 1,
                hostArguments: ["/test-host", "--filter", "old"],
                deadlineRunner: { _, environment, _, _ in
                    let staging = try URL(fileURLWithPath: #require(
                        environment[ProductionReplayEnvironmentKey.resultPath]
                    ))
                    failedStaging = staging
                    try Data("untrusted".utf8).write(to: staging)
                    throw SubprocessDeadlineGuardError.childFailed(exitCode: 1)
                }
            )
        }
        #expect(try Data(contentsOf: scratch.result) == Data("trusted".utf8))
        #expect(failedStaging.map {
            !FileManager.default.fileExists(atPath: $0.path)
        } == true)

        let skipped = try ProductionReplayDriver.run(
            victim: victim,
            input: input,
            deadlineSeconds: 1,
            hostArguments: ["/test-host", "--filter", "old"],
            deadlineRunner: { _, environment, _, _ in
                let staging = try URL(fileURLWithPath: #require(
                    environment[ProductionReplayEnvironmentKey.resultPath]
                ))
                try Data("skipped".utf8).write(to: staging)
                return .skippedUnsupportedHost(reason: "self-test")
            }
        )
        #expect(skipped.outcome == .skippedUnsupportedHost(reason: "self-test"))
        #expect(throws: ProductionReplayDriverError.resultUnavailable) {
            _ = try skipped.resultData()
        }
        #expect(try Data(contentsOf: scratch.result) == Data("trusted".utf8))
        #expect(try stagingArtifacts(in: scratch.directory).isEmpty)
    }

    @Test("Completed outcome without a fresh regular staging file fails closed")
    func completedWithoutStagingFailsClosed() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        try Data("trusted".utf8).write(to: scratch.result)
        let victim = try makeVictim()
        let input = try makeInput(resultURL: scratch.result)
        #expect(throws: ProductionReplayDriverError.self) {
            _ = try ProductionReplayDriver.run(
                victim: victim,
                input: input,
                deadlineSeconds: 1,
                hostArguments: ["/test-host", "--filter", "old"],
                deadlineRunner: { _, _, _, _ in .completed }
            )
        }
        #expect(try Data(contentsOf: scratch.result) == Data("trusted".utf8))
        #expect(try stagingArtifacts(in: scratch.directory).isEmpty)
    }

    @Test("Invalid deadlines fail before launch or filesystem mutation")
    func invalidDeadlinesFailBeforeLaunch() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        try Data("trusted".utf8).write(to: scratch.result)
        let victim = try makeVictim()
        let input = try makeInput(resultURL: scratch.result)

        let invalidDeadlines: [Double] = [
            0,
            -1,
            .infinity,
            -.infinity,
            .nan,
        ]
        for deadline in invalidDeadlines {
            var launched = false
            #expect(throws: ProductionReplayDriverError.invalidDeadline) {
                _ = try ProductionReplayDriver.run(
                    victim: victim,
                    input: input,
                    deadlineSeconds: deadline,
                    deadlineRunner: { _, _, _, _ in
                        launched = true
                        return .completed
                    }
                )
            }
            #expect(!launched)
            #expect(try Data(contentsOf: scratch.result) == Data("trusted".utf8))
            #expect(try stagingArtifacts(in: scratch.directory).isEmpty)
        }

        var launched = false
        _ = try ProductionReplayDriver.run(
            victim: victim,
            input: input,
            deadlineSeconds: .leastNonzeroMagnitude,
            deadlineRunner: { _, _, _, _ in
                launched = true
                return .skippedUnsupportedHost(reason: "boundary")
            }
        )
        #expect(launched)
    }

    @Test("Child assertion failure cannot create its staging artifact")
    func childAssertionFailureWritesNothing() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let staging = scratch.directory.appendingPathComponent("assertion.staging")
        let input = try makeInput(resultURL: scratch.result)
        let context = try ProductionReplayChildContext<ReplayDriverSelfTestCheckpoint>(
            environment: input.environmentVariables(
                stagingResultURL: staging
            )
        )
        #expect(throws: ReplayDriverSafetyTestError.assertionFailed) {
            try context.complete(resultData: Data("untrusted".utf8)) {
                throw ReplayDriverSafetyTestError.assertionFailed
            }
        }
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }
}
