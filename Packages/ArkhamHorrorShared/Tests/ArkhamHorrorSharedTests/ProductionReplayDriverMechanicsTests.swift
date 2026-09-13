import Foundation
import Testing

// swiftlint:disable file_length

enum ReplayDriverSelfTestCheckpoint: String, ProductionReplayCheckpoint {
    case assignmentContinuation = "assignment-continuation"
}

enum ReplayDriverSelfTestEnvironmentKey {
    static let evidence = "ARKHAM_PRODUCTION_REPLAY_SELFTEST_EVIDENCE"
}

@Suite("Production replay driver victim")
struct ReplayDriverSelfTestSuite {
    @Test("Subprocess-only replay victim")
    func productionReplayDriverSelfTestVictim() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[ProductionReplayEnvironmentKey.checkpoint] != nil else {
            return
        }
        let context = try ProductionReplayChildContext<ReplayDriverSelfTestCheckpoint>(
            environment: environment
        )
        let evidence = environment[ReplayDriverSelfTestEnvironmentKey.evidence]
        try context.complete(
            resultData: Data("assignment-continuation|injected".utf8),
            afterAssertions: {
                try #require(context.checkpoint == .assignmentContinuation)
                try #require(evidence == "injected")
            }
        )
    }
}

@Suite("Ambiguous replay driver victim")
struct ReplayDriverAmbiguousSelfTestSuite {
    @Test("A same-named test in another suite must never join the child")
    func productionReplayDriverSelfTestVictim() {
        #expect(
            ProcessInfo.processInfo.environment[
                ProductionReplayEnvironmentKey.checkpoint
            ] == nil
        )
    }
}

@Suite("Production replay driver mechanics")
// swiftlint:disable:next type_body_length
struct ProductionReplayDriverMechanicsTests {
    @Test("Victim filters match one complete module, suite, and function identifier")
    func victimFilterIsFullyAnchored() throws {
        let victim = try makeVictim()
        #expect(victim.discoveredIdentifier
            == "ArkhamHorrorSharedTests.ReplayDriverSelfTestSuite/" +
            "productionReplayDriverSelfTestVictim()")
        let regex = try NSRegularExpression(pattern: victim.exactFilter)
        #expect(matches(regex, victim.discoveredIdentifier + "/case"))
        #expect(!matches(
            regex,
            "ArkhamHorrorSharedTests.ReplayDriverAmbiguousSelfTestSuite/" +
                "productionReplayDriverSelfTestVictim()/case"
        ))
        #expect(!matches(
            regex,
            "OtherModule.ReplayDriverSelfTestSuite/" +
                "productionReplayDriverSelfTestVictim()/case"
        ))
        #expect(!matches(regex, "productionReplayDriverSelfTestVictim()"))
        #expect(matches(regex, victim.discoveredIdentifier))
        #expect(!matches(regex, "Prefix." + victim.discoveredIdentifier + "/case"))
        #expect(!matches(regex, victim.discoveredIdentifier + "/case/nested"))

        for component in ["", "victim.*", "Nested/Suite"] {
            #expect(throws: ProductionReplayDriverError.self) {
                _ = try ProductionReplayVictim(
                    moduleName: component,
                    suiteName: "ReplayDriverSelfTestSuite",
                    functionName: "productionReplayDriverSelfTestVictim"
                )
            }
        }
    }

    @Test("Typed checkpoint and staging path round-trip through reserved environment keys")
    func typedEnvironmentRoundTrip() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let input = try makeInput(resultURL: scratch.result)
        let staging = scratch.directory.appendingPathComponent("child.staging")
        let environment = try input.environmentVariables(
            stagingResultURL: staging
        )
        #expect(environment[ProductionReplayEnvironmentKey.checkpoint]
            == ReplayDriverSelfTestCheckpoint.assignmentContinuation.rawValue)
        #expect(environment[ProductionReplayEnvironmentKey.resultPath] == staging.path)
        #expect(
            Int32(environment[ProductionReplayEnvironmentKey.parentDevice] ?? "")
                != nil
        )
        #expect(
            UInt64(environment[ProductionReplayEnvironmentKey.parentInode] ?? "")
                != nil
        )
        #expect(environment[ReplayDriverSelfTestEnvironmentKey.evidence] == "injected")

        let child = try ProductionReplayChildContext<ReplayDriverSelfTestCheckpoint>(
            environment: environment
        )
        #expect(child.checkpoint == .assignmentContinuation)
        #expect(child.resultURL == staging)
        for key in ProductionReplayEnvironmentKey.reserved {
            #expect(throws: ProductionReplayDriverError.reservedEnvironmentKey(key)) {
                _ = try ProductionReplayInput(
                    checkpoint: ReplayDriverSelfTestCheckpoint.assignmentContinuation,
                    resultURL: scratch.result,
                    additionalEnvironment: [key: "collision"]
                )
            }
        }
    }

    @Test("Missing, unknown, and malformed child environment fails closed")
    func malformedChildEnvironmentFailsClosed() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        #expect(throws: ProductionReplayDriverError.self) {
            _ = try ProductionReplayChildContext<ReplayDriverSelfTestCheckpoint>(
                environment: [:]
            )
        }
        #expect(throws: ProductionReplayDriverError.self) {
            _ = try ProductionReplayChildContext<ReplayDriverSelfTestCheckpoint>(
                environment: [
                    ProductionReplayEnvironmentKey.checkpoint: "unknown",
                    ProductionReplayEnvironmentKey.resultPath: scratch.result.path,
                ]
            )
        }
        #expect(throws: ProductionReplayDriverError.self) {
            _ = try ProductionReplayChildContext<ReplayDriverSelfTestCheckpoint>(
                environment: [
                    ProductionReplayEnvironmentKey.checkpoint:
                        ReplayDriverSelfTestCheckpoint.assignmentContinuation.rawValue,
                ]
            )
        }
        #expect(throws: ProductionReplayDriverError.self) {
            _ = try ProductionReplayChildContext<ReplayDriverSelfTestCheckpoint>(
                environment: [
                    ProductionReplayEnvironmentKey.checkpoint:
                        ReplayDriverSelfTestCheckpoint.assignmentContinuation.rawValue,
                    ProductionReplayEnvironmentKey.resultPath: "relative/result.json",
                ]
            )
        }
    }

    @Test("Missing and malformed parent identity fail closed")
    func malformedParentIdentityFailsClosed() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let environment = try makeInput(resultURL: scratch.result)
            .environmentVariables(
                stagingResultURL: scratch.directory.appendingPathComponent(
                    "child.staging"
                )
            )
        #expect(throws: ProductionReplayDriverError.missingParentIdentity) {
            var missingIdentity = environment
            missingIdentity.removeValue(
                forKey: ProductionReplayEnvironmentKey.parentDevice
            )
            _ = try ProductionReplayChildContext<ReplayDriverSelfTestCheckpoint>(
                environment: missingIdentity
            )
        }
        #expect(throws: ProductionReplayDriverError.invalidParentIdentity) {
            var invalidIdentity = environment
            invalidIdentity[ProductionReplayEnvironmentKey.parentInode] = "NaN"
            _ = try ProductionReplayChildContext<ReplayDriverSelfTestCheckpoint>(
                environment: invalidIdentity
            )
        }
    }

    @Test("Completed child atomically replaces only the final regular file")
    func completedChildPublishesStagingAtomically() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        try Data("stable".utf8).write(to: scratch.result)
        let victim = try makeVictim()
        let input = try makeInput(resultURL: scratch.result)
        var observedStagingURL: URL?

        let result = try ProductionReplayDriver.run(
            victim: victim,
            input: input,
            deadlineSeconds: 12.5,
            hostArguments: ["/test-host", "--filter", "old"],
            deadlineRunner: { filter, environment, deadline, hostArguments in
                #expect(filter == victim.exactFilter)
                #expect(deadline == 12.5)
                #expect(hostArguments == ["/test-host", "--filter", "old"])
                #expect(environment[ProductionReplayEnvironmentKey.checkpoint]
                    == ReplayDriverSelfTestCheckpoint.assignmentContinuation.rawValue)
                #expect(environment[ReplayDriverSelfTestEnvironmentKey.evidence]
                    == "injected")
                #expect(try Data(contentsOf: scratch.result) == Data("stable".utf8))
                let staging = try URL(fileURLWithPath: #require(
                    environment[ProductionReplayEnvironmentKey.resultPath]
                ))
                observedStagingURL = staging
                #expect(staging.deletingLastPathComponent() == scratch.directory)
                #expect(staging != scratch.result)
                #expect(!FileManager.default.fileExists(atPath: staging.path))
                try Data("fresh".utf8).write(to: staging)
                return .completed
            }
        )

        #expect(result.outcome == .completed)
        #expect(try result.resultData() == Data("fresh".utf8))
        #expect(try Data(contentsOf: scratch.result) == Data("fresh".utf8))
        #expect(observedStagingURL.map {
            !FileManager.default.fileExists(atPath: $0.path)
        } == true)
        #expect(try stagingArtifacts(in: scratch.directory).isEmpty)
    }

    @Test("Artifact validation happens before publication")
    func invalidArtifactDoesNotReplaceFinalResult() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        try Data("stable".utf8).write(to: scratch.result)
        var observedStagingURL: URL?

        #expect(throws: ProductionReplayDriverError.resultUnavailable) {
            _ = try ProductionReplayDriver.run(
                victim: makeVictim(),
                input: makeInput(resultURL: scratch.result),
                deadlineSeconds: 1,
                artifactValidator: { data in
                    #expect(data == Data("invalid".utf8))
                    throw ProductionReplayDriverError.resultUnavailable
                },
                deadlineRunner: { _, environment, _, _ in
                    let staging = try URL(fileURLWithPath: #require(
                        environment[ProductionReplayEnvironmentKey.resultPath]
                    ))
                    observedStagingURL = staging
                    try Data("invalid".utf8).write(to: staging)
                    return .completed
                }
            )
        }

        #expect(try Data(contentsOf: scratch.result) == Data("stable".utf8))
        #expect(observedStagingURL.map {
            !FileManager.default.fileExists(atPath: $0.path)
        } == true)
        #expect(try stagingArtifacts(in: scratch.directory).isEmpty)
    }

    @Test("Oversized staging artifacts are rejected before validation")
    func oversizedStagingArtifactRejected() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        try Data("stable".utf8).write(to: scratch.result)
        var validatorCalled = false

        #expect(throws: ProductionReplayDriverError.resultTooLarge) {
            _ = try ProductionReplayDriver.run(
                victim: makeVictim(),
                input: makeInput(resultURL: scratch.result),
                deadlineSeconds: 1,
                artifactValidator: { _ in
                    validatorCalled = true
                },
                deadlineRunner: { _, environment, _, _ in
                    let staging = try URL(fileURLWithPath: #require(
                        environment[ProductionReplayEnvironmentKey.resultPath]
                    ))
                    try Data(
                        repeating: 0x41,
                        count:
                        ProductionReplayFileSystem.maximumArtifactByteCount + 1
                    ).write(to: staging)
                    return .completed
                }
            )
        }

        #expect(!validatorCalled)
        #expect(try Data(contentsOf: scratch.result) == Data("stable".utf8))
        #expect(try stagingArtifacts(in: scratch.directory).isEmpty)
    }

    @Test("Oversized published artifacts cannot be read")
    func oversizedPublishedArtifactRejected() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        try Data(
            repeating: 0x42,
            count: ProductionReplayFileSystem.maximumArtifactByteCount + 1
        ).write(to: scratch.result)
        let destination =
            try ProductionReplayFileSystem.validateFinalDestination(
                scratch.result
            )

        #expect(throws: ProductionReplayDriverError.resultTooLarge) {
            _ = try ProductionReplayFileSystem.readPublishedArtifact(
                destination
            )
        }
    }

    @Test("Completion deadline gates validation and publication")
    func completionDeadlineGatesPublication() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        try Data("stable".utf8).write(to: scratch.result)
        var failedChecks = 0

        #expect(throws: ProductionReplayDriverError.invalidDeadline) {
            _ = try ProductionReplayDriver.run(
                victim: makeVictim(),
                input: makeInput(resultURL: scratch.result),
                deadlineSeconds: 1,
                completionDeadlineValidator: {
                    failedChecks += 1
                    if failedChecks == 2 {
                        throw ProductionReplayDriverError.invalidDeadline
                    }
                },
                deadlineRunner: { _, environment, _, _ in
                    let staging = try URL(fileURLWithPath: #require(
                        environment[ProductionReplayEnvironmentKey.resultPath]
                    ))
                    try Data("late".utf8).write(to: staging)
                    return .completed
                }
            )
        }
        #expect(failedChecks == 2)
        #expect(try Data(contentsOf: scratch.result) == Data("stable".utf8))

        var successfulChecks = 0
        let result = try ProductionReplayDriver.run(
            victim: makeVictim(),
            input: makeInput(resultURL: scratch.result),
            deadlineSeconds: 1,
            completionDeadlineValidator: {
                successfulChecks += 1
            },
            deadlineRunner: { _, environment, _, _ in
                let staging = try URL(fileURLWithPath: #require(
                    environment[ProductionReplayEnvironmentKey.resultPath]
                ))
                try Data("fresh".utf8).write(to: staging)
                return .completed
            }
        )
        #expect(successfulChecks == 2)
        #expect(try result.resultData() == Data("fresh".utf8))
    }

    @Test("A real child publishes only after its sentinel-proven success")
    func realChildCompletesWithReusableResult() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let result = try ProductionReplayDriver.run(
            victim: makeVictim(),
            input: makeInput(resultURL: scratch.result),
            deadlineSeconds: 20
        )
        if case let .skippedUnsupportedHost(reason) = result.outcome {
            Issue.record(
                Comment(rawValue: "Skipped replay-driver child mechanics: \(reason)"),
                severity: .warning
            )
            return
        }
        #expect(result.outcome == .completed)
        #expect(try result.resultData() == Data("assignment-continuation|injected".utf8))
        #expect(try stagingArtifacts(in: scratch.directory).isEmpty)
    }

    private func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        regex.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ) != nil
    }
}

func makeVictim() throws -> ProductionReplayVictim {
    try ProductionReplayVictim(
        moduleName: "ArkhamHorrorSharedTests",
        suiteName: "ReplayDriverSelfTestSuite",
        functionName: "productionReplayDriverSelfTestVictim"
    )
}

func makeInput(
    resultURL: URL
) throws -> ProductionReplayInput<ReplayDriverSelfTestCheckpoint> {
    try ProductionReplayInput(
        checkpoint: ReplayDriverSelfTestCheckpoint.assignmentContinuation,
        resultURL: resultURL,
        additionalEnvironment: [ReplayDriverSelfTestEnvironmentKey.evidence: "injected"]
    )
}

func stagingArtifacts(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter {
        $0.lastPathComponent.contains(".production-replay-")
            && $0.pathExtension == "staging"
    }
}

func makeScratch() throws -> (directory: URL, result: URL) {
    let directory = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    )
    .appendingPathComponent(".build", isDirectory: true)
    .appendingPathComponent(
        "production-replay-driver-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
    )
    return (directory, directory.appendingPathComponent("result.json"))
}
