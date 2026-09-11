import Darwin
import Foundation
import Testing

@Suite("Production replay driver ancestor safety")
struct ReplayDriverAncestorSafetyTests {
    @Test("Symlinked ancestors at multiple depths fail closed")
    func symlinkedAncestorsFailClosed() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let target = scratch.directory.appendingPathComponent(
            "redirect-target",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )

        let shallowLink = scratch.directory.appendingPathComponent("shallow-link")
        try FileManager.default.createSymbolicLink(
            at: shallowLink,
            withDestinationURL: target
        )
        let shallowResult = shallowLink
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("result.json")
        #expect(throws: ProductionReplayDriverError.invalidResultParent) {
            _ = try makeInput(resultURL: shallowResult)
        }

        let safePrefix = scratch.directory
            .appendingPathComponent("safe", isDirectory: true)
            .appendingPathComponent("deeper", isDirectory: true)
        try FileManager.default.createDirectory(
            at: safePrefix,
            withIntermediateDirectories: true
        )
        let deepLink = safePrefix.appendingPathComponent("deep-link")
        try FileManager.default.createSymbolicLink(
            at: deepLink,
            withDestinationURL: target
        )
        let deepResult = deepLink
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("result.json")
        #expect(throws: ProductionReplayDriverError.invalidResultParent) {
            _ = try makeInput(resultURL: deepResult)
        }

        #expect(!FileManager.default.fileExists(
            atPath: target.appendingPathComponent("nested/result.json").path
        ))
    }

    @Test("Regular and special-file ancestors fail closed")
    func nonDirectoryAncestorsFailClosed() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.directory) }
        let regular = scratch.directory.appendingPathComponent("regular")
        try Data("not a directory".utf8).write(to: regular)
        #expect(throws: ProductionReplayDriverError.invalidResultParent) {
            _ = try makeInput(
                resultURL: regular.appendingPathComponent("nested/result.json")
            )
        }

        let fifo = scratch.directory.appendingPathComponent("fifo")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: ProductionReplayDriverError.invalidResultParent) {
            _ = try makeInput(
                resultURL: fifo.appendingPathComponent("nested/result.json")
            )
        }
    }

    @Test("Child rejects a path rebound to a different parent identity")
    func childRejectsReboundParent() throws {
        let fixture = try makeNestedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch.directory) }
        let input = try makeInput(resultURL: fixture.result)
        let environment = try input.environmentVariables(
            stagingResultURL: fixture.staging
        )

        try replaceRoute(fixture)

        #expect(throws: ProductionReplayDriverError.unsafeResultParent) {
            _ = try ProductionReplayChildContext<ReplayDriverSelfTestCheckpoint>(
                environment: environment
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.displacedParent
                .appendingPathComponent(fixture.staging.lastPathComponent).path
        ))
    }

    @Test("Child writes remain bound to the validated parent descriptor")
    func childWriteRemainsDescriptorBound() throws {
        let fixture = try makeNestedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch.directory) }
        let input = try makeInput(resultURL: fixture.result)
        let context = try ProductionReplayChildContext<ReplayDriverSelfTestCheckpoint>(
            environment: input.environmentVariables(
                stagingResultURL: fixture.staging
            )
        )

        try context.complete(resultData: Data("trusted".utf8)) {
            try replaceRoute(fixture)
        }

        let displacedStaging = fixture.displacedParent.appendingPathComponent(
            fixture.staging.lastPathComponent
        )
        #expect(try Data(contentsOf: displacedStaging) == Data("trusted".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
    }

    @Test("Ancestor replacement before publication preserves both destinations")
    func ancestorReplacementBeforePublishFailsClosed() throws {
        let fixture = try makeNestedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch.directory) }
        try Data("stable".utf8).write(to: fixture.result)
        let input = try makeInput(resultURL: fixture.result)
        var stagingName: String?

        #expect(throws: ProductionReplayDriverError.unsafeResultParent) {
            _ = try ProductionReplayDriver.run(
                victim: makeVictim(),
                input: input,
                deadlineSeconds: 1,
                deadlineRunner: { _, environment, _, _ in
                    let staging = try URL(fileURLWithPath: #require(
                        environment[ProductionReplayEnvironmentKey.resultPath]
                    ))
                    stagingName = staging.lastPathComponent
                    try Data("untrusted".utf8).write(to: staging)
                    try replaceRoute(fixture)
                    try Data("redirect".utf8).write(to: fixture.result)
                    return .completed
                }
            )
        }

        let displacedResult = fixture.displacedParent.appendingPathComponent(
            fixture.result.lastPathComponent
        )
        #expect(try Data(contentsOf: displacedResult) == Data("stable".utf8))
        #expect(try Data(contentsOf: fixture.result) == Data("redirect".utf8))
        if let stagingName {
            #expect(!FileManager.default.fileExists(
                atPath: fixture.displacedParent
                    .appendingPathComponent(stagingName).path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.parent.appendingPathComponent(stagingName).path
            ))
        }
    }

    @Test("Published result reads remain bound to the validated parent")
    func publishedResultReadRemainsDescriptorBound() throws {
        let fixture = try makeNestedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch.directory) }
        let result = try ProductionReplayDriver.run(
            victim: makeVictim(),
            input: makeInput(resultURL: fixture.result),
            deadlineSeconds: 1,
            deadlineRunner: { _, environment, _, _ in
                let staging = try URL(fileURLWithPath: #require(
                    environment[ProductionReplayEnvironmentKey.resultPath]
                ))
                try Data("published".utf8).write(to: staging)
                return .completed
            }
        )

        try replaceRoute(fixture)
        try Data("redirect".utf8).write(to: fixture.result)

        #expect(try result.resultData() == Data("published".utf8))
        #expect(try Data(contentsOf: fixture.result) == Data("redirect".utf8))
        #expect(try Data(
            contentsOf: fixture.displacedParent.appendingPathComponent(
                fixture.result.lastPathComponent
            )
        ) == Data("published".utf8))
    }

    private func makeNestedFixture() throws -> NestedReplayFixture {
        let scratch = try makeScratch()
        let route = scratch.directory.appendingPathComponent(
            "route",
            isDirectory: true
        )
        let parent = route
            .appendingPathComponent("one", isDirectory: true)
            .appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let displacedRoute = scratch.directory.appendingPathComponent(
            "displaced-route",
            isDirectory: true
        )
        return NestedReplayFixture(
            scratch: scratch,
            route: route,
            parent: parent,
            displacedRoute: displacedRoute,
            displacedParent: displacedRoute
                .appendingPathComponent("one", isDirectory: true)
                .appendingPathComponent("two", isDirectory: true),
            result: parent.appendingPathComponent("result.json"),
            staging: parent.appendingPathComponent("child.staging")
        )
    }

    private func replaceRoute(_ fixture: NestedReplayFixture) throws {
        try FileManager.default.moveItem(
            at: fixture.route,
            to: fixture.displacedRoute
        )
        try FileManager.default.createDirectory(
            at: fixture.parent,
            withIntermediateDirectories: true
        )
    }
}

private struct NestedReplayFixture {
    let scratch: (directory: URL, result: URL)
    let route: URL
    let parent: URL
    let displacedRoute: URL
    let displacedParent: URL
    let result: URL
    let staging: URL
}
