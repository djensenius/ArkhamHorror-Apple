import Darwin
import Foundation

protocol ProductionReplayCheckpoint: RawRepresentable, Sendable where RawValue == String {}

enum ProductionReplayDriverError: Error, Equatable {
    case invalidVictimIdentifier(String)
    case reservedEnvironmentKey(String)
    case invalidResultURL
    case invalidResultParent
    case unsafeResultParent
    case resultDestinationNotRegular
    case stagingPathUnavailable
    case resultMissingOrNotRegular
    case resultPublishFailed(Int32)
    case resultUnavailable
    case invalidDeadline
    case missingCheckpoint
    case unsupportedCheckpoint(String)
    case missingResultPath
}

enum ProductionReplayEnvironmentKey {
    static let checkpoint = "ARKHAM_PRODUCTION_REPLAY_CHECKPOINT"
    static let resultPath = "ARKHAM_PRODUCTION_REPLAY_RESULT_PATH"

    static let reserved = Set([checkpoint, resultPath])
}

struct ProductionReplayVictim: Sendable, Equatable {
    let moduleName: String
    let suiteName: String
    let functionName: String

    init(
        moduleName: String,
        suiteName: String,
        functionName: String
    ) throws {
        for component in [moduleName, suiteName, functionName] {
            guard Self.isASCIIIdentifier(component) else {
                throw ProductionReplayDriverError.invalidVictimIdentifier(component)
            }
        }
        self.moduleName = moduleName
        self.suiteName = suiteName
        self.functionName = functionName
    }

    var discoveredIdentifier: String {
        "\(moduleName).\(suiteName)/\(functionName)()"
    }

    /// SwiftPM matches against the complete discovered identifier followed by one internal
    /// test-case component. Escaping the full module/suite/function path, requiring exactly
    /// that one terminal component, and anchoring the end prevents a same-named test in
    /// another suite or module from joining the replay subprocess.
    var exactFilter: String {
        let escaped = NSRegularExpression.escapedPattern(for: discoveredIdentifier)
        return "^\(escaped)/[^/]+$"
    }

    private static func isASCIIIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              first == 0x5F || (0x41 ... 0x5A).contains(first)
              || (0x61 ... 0x7A).contains(first)
        else { return false }
        return value.utf8.dropFirst().allSatisfy {
            $0 == 0x5F || (0x30 ... 0x39).contains($0)
                || (0x41 ... 0x5A).contains($0)
                || (0x61 ... 0x7A).contains($0)
        }
    }
}

struct ProductionReplayInput<Checkpoint: ProductionReplayCheckpoint>: Sendable {
    let checkpoint: Checkpoint
    let resultURL: URL
    let additionalEnvironment: [String: String]

    init(
        checkpoint: Checkpoint,
        resultURL: URL,
        additionalEnvironment: [String: String] = [:]
    ) throws {
        let destination = try ProductionReplayFileSystem.validateFinalDestination(
            resultURL
        )
        if let collision = additionalEnvironment.keys.first(
            where: ProductionReplayEnvironmentKey.reserved.contains
        ) {
            throw ProductionReplayDriverError.reservedEnvironmentKey(collision)
        }
        self.checkpoint = checkpoint
        self.resultURL = destination.finalURL
        self.additionalEnvironment = additionalEnvironment
    }

    func environmentVariables(stagingResultURL: URL) -> [String: String] {
        var variables = additionalEnvironment
        variables[ProductionReplayEnvironmentKey.checkpoint] = checkpoint.rawValue
        variables[ProductionReplayEnvironmentKey.resultPath] = stagingResultURL.path
        return variables
    }
}

struct ProductionReplayChildContext<Checkpoint: ProductionReplayCheckpoint>: Sendable {
    let checkpoint: Checkpoint
    let resultURL: URL
    private let parentIdentity: ProductionReplayParentIdentity

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let rawCheckpoint = environment[ProductionReplayEnvironmentKey.checkpoint] else {
            throw ProductionReplayDriverError.missingCheckpoint
        }
        guard let checkpoint = Checkpoint(rawValue: rawCheckpoint) else {
            throw ProductionReplayDriverError.unsupportedCheckpoint(rawCheckpoint)
        }
        guard let resultPath = environment[ProductionReplayEnvironmentKey.resultPath] else {
            throw ProductionReplayDriverError.missingResultPath
        }
        guard resultPath.hasPrefix("/") else {
            throw ProductionReplayDriverError.invalidResultURL
        }
        let staging = try ProductionReplayFileSystem.validateNewStagingDestination(
            URL(fileURLWithPath: resultPath)
        )
        self.checkpoint = checkpoint
        resultURL = staging.finalURL
        parentIdentity = staging.parentIdentity
    }

    /// Assertions run first. The child then writes only its unique staging file, validates
    /// that regular file, and records the completion sentinel last. The parent is solely
    /// responsible for publishing the staging bytes to the caller's final destination.
    func complete(
        resultData: Data,
        afterAssertions assertions: () throws -> Void
    ) throws {
        try assertions()
        try resultData.write(to: resultURL, options: .atomic)
        try ProductionReplayFileSystem.validateStagingArtifact(
            resultURL,
            parentIdentity: parentIdentity
        )
        SubprocessDeadlineGuard.recordVictimCompletion()
    }
}

struct ProductionReplayRunResult: Equatable {
    let outcome: SubprocessDeadlineGuardOutcome
    let resultURL: URL

    func resultData() throws -> Data {
        guard outcome == .completed else {
            throw ProductionReplayDriverError.resultUnavailable
        }
        try ProductionReplayFileSystem.validatePublishedArtifact(resultURL)
        return try Data(contentsOf: resultURL)
    }
}

typealias ProductionReplayDeadlineRunner = (
    _ victimFilter: String,
    _ additionalEnvironment: [String: String],
    _ deadlineSeconds: Double,
    _ hostArguments: [String]
) throws -> SubprocessDeadlineGuardOutcome

enum ProductionReplayDriver {
    static func run(
        victim: ProductionReplayVictim,
        input: ProductionReplayInput<some ProductionReplayCheckpoint>,
        deadlineSeconds: Double,
        hostArguments: [String] = CommandLine.arguments,
        deadlineRunner: ProductionReplayDeadlineRunner = runDeadlineGuard
    ) throws -> ProductionReplayRunResult {
        guard deadlineSeconds.isFinite, deadlineSeconds > 0 else {
            throw ProductionReplayDriverError.invalidDeadline
        }

        let destination = try ProductionReplayFileSystem.validateFinalDestination(
            input.resultURL
        )
        let stagingURL = try ProductionReplayFileSystem.makeStagingURL(
            for: destination
        )
        defer { ProductionReplayFileSystem.removeStagingIfPresent(stagingURL) }

        let outcome = try deadlineRunner(
            victim.exactFilter,
            input.environmentVariables(stagingResultURL: stagingURL),
            deadlineSeconds,
            hostArguments
        )
        guard outcome == .completed else {
            return ProductionReplayRunResult(
                outcome: outcome,
                resultURL: destination.finalURL
            )
        }

        try ProductionReplayFileSystem.validateStagingArtifact(
            stagingURL,
            parentIdentity: destination.parentIdentity
        )
        try ProductionReplayFileSystem.publish(
            stagingURL,
            to: destination
        )
        return ProductionReplayRunResult(
            outcome: outcome,
            resultURL: destination.finalURL
        )
    }

    private static func runDeadlineGuard(
        victimFilter: String,
        additionalEnvironment: [String: String],
        deadlineSeconds: Double,
        hostArguments: [String]
    ) throws -> SubprocessDeadlineGuardOutcome {
        try SubprocessDeadlineGuard.runFiltered(
            victimFilter: victimFilter,
            additionalEnvironment: additionalEnvironment,
            deadlineSeconds: deadlineSeconds,
            hostArguments: hostArguments
        )
    }
}

private struct ProductionReplayParentIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
}

private struct ProductionReplayDestination {
    let finalURL: URL
    let parentURL: URL
    let parentIdentity: ProductionReplayParentIdentity
}

private enum ProductionReplayFileSystem {
    static func validateFinalDestination(
        _ resultURL: URL
    ) throws -> ProductionReplayDestination {
        let normalized = try normalizedFileURL(resultURL)
        let parentURL = normalized.deletingLastPathComponent()
        guard parentURL.path != normalized.path else {
            throw ProductionReplayDriverError.invalidResultURL
        }
        let parentIdentity = try validateParent(parentURL)

        var info = stat()
        if lstat(normalized.path, &info) == 0 {
            guard isRegular(info) else {
                throw ProductionReplayDriverError.resultDestinationNotRegular
            }
        } else if errno != ENOENT {
            throw ProductionReplayDriverError.invalidResultURL
        }
        return ProductionReplayDestination(
            finalURL: normalized,
            parentURL: parentURL,
            parentIdentity: parentIdentity
        )
    }

    static func validateNewStagingDestination(
        _ resultURL: URL
    ) throws -> ProductionReplayDestination {
        let destination = try validateFinalDestination(resultURL)
        var info = stat()
        guard lstat(destination.finalURL.path, &info) != 0, errno == ENOENT else {
            throw ProductionReplayDriverError.stagingPathUnavailable
        }
        return destination
    }

    static func makeStagingURL(
        for destination: ProductionReplayDestination
    ) throws -> URL {
        for _ in 0 ..< 8 {
            let url = destination.parentURL.appendingPathComponent(
                ".\(destination.finalURL.lastPathComponent).production-replay-" +
                    "\(UUID().uuidString).staging"
            )
            var info = stat()
            if lstat(url.path, &info) != 0, errno == ENOENT {
                return url
            }
        }
        throw ProductionReplayDriverError.stagingPathUnavailable
    }

    static func validateStagingArtifact(
        _ stagingURL: URL,
        parentIdentity: ProductionReplayParentIdentity
    ) throws {
        let currentParent = try validateParent(
            stagingURL.deletingLastPathComponent()
        )
        guard currentParent == parentIdentity else {
            throw ProductionReplayDriverError.unsafeResultParent
        }
        var info = stat()
        guard lstat(stagingURL.path, &info) == 0,
              isRegular(info),
              info.st_dev == parentIdentity.device,
              info.st_uid == geteuid(),
              info.st_nlink == 1
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
    }

    static func validatePublishedArtifact(_ resultURL: URL) throws {
        let destination = try validateFinalDestination(resultURL)
        var info = stat()
        guard lstat(destination.finalURL.path, &info) == 0,
              isRegular(info),
              info.st_dev == destination.parentIdentity.device
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
    }

    static func publish(
        _ stagingURL: URL,
        to destination: ProductionReplayDestination
    ) throws {
        let currentDestination = try validateFinalDestination(destination.finalURL)
        guard currentDestination.parentIdentity == destination.parentIdentity else {
            throw ProductionReplayDriverError.unsafeResultParent
        }
        guard rename(stagingURL.path, destination.finalURL.path) == 0 else {
            throw ProductionReplayDriverError.resultPublishFailed(errno)
        }
        try validatePublishedArtifact(destination.finalURL)
    }

    static func removeStagingIfPresent(_ stagingURL: URL) {
        guard unlink(stagingURL.path) != 0, errno != ENOENT else { return }
        _ = rmdir(stagingURL.path)
    }

    private static func normalizedFileURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw ProductionReplayDriverError.invalidResultURL
        }
        return url.standardizedFileURL
    }

    private static func validateParent(
        _ parentURL: URL
    ) throws -> ProductionReplayParentIdentity {
        var info = stat()
        guard lstat(parentURL.path, &info) == 0, isDirectory(info) else {
            throw ProductionReplayDriverError.invalidResultParent
        }
        guard info.st_uid == geteuid(),
              info.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            throw ProductionReplayDriverError.unsafeResultParent
        }
        return ProductionReplayParentIdentity(
            device: info.st_dev,
            inode: info.st_ino
        )
    }

    private static func isDirectory(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFDIR
    }

    private static func isRegular(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG
    }
}
