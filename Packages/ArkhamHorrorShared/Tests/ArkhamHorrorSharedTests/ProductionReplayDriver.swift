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
    case resultWriteFailed(Int32)
    case resultPublishFailed(Int32)
    case resultUnavailable
    case inputAlreadyRead
    case privateDirectoryUnavailable
    case unexpectedDirectoryEntry(String)
    case invalidDeadline
    case missingCheckpoint
    case unsupportedCheckpoint(String)
    case missingResultPath
    case missingParentIdentity
    case invalidParentIdentity
}

enum ProductionReplayEnvironmentKey {
    static let checkpoint = "ARKHAM_PRODUCTION_REPLAY_CHECKPOINT"
    static let resultPath = "ARKHAM_PRODUCTION_REPLAY_RESULT_PATH"
    static let parentDevice = "ARKHAM_PRODUCTION_REPLAY_PARENT_DEVICE"
    static let parentInode = "ARKHAM_PRODUCTION_REPLAY_PARENT_INODE"

    static let reserved = Set([
        checkpoint,
        resultPath,
        parentDevice,
        parentInode,
    ])
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

    func environmentVariables(stagingResultURL: URL) throws -> [String: String] {
        let staging = try ProductionReplayFileSystem.validateNewStagingDestination(
            stagingResultURL
        )
        return environmentVariables(
            stagingResultURL: stagingResultURL,
            parentIdentity: staging.parent.identity
        )
    }

    func environmentVariables(
        stagingResultURL: URL,
        parentIdentity: ProductionReplayParentIdentity
    ) -> [String: String] {
        var variables = additionalEnvironment
        variables[ProductionReplayEnvironmentKey.checkpoint] = checkpoint.rawValue
        variables[ProductionReplayEnvironmentKey.resultPath] = stagingResultURL.path
        variables[ProductionReplayEnvironmentKey.parentDevice] =
            String(parentIdentity.device)
        variables[ProductionReplayEnvironmentKey.parentInode] =
            String(parentIdentity.inode)
        return variables
    }
}

struct ProductionReplayChildContext<Checkpoint: ProductionReplayCheckpoint>: Sendable {
    let checkpoint: Checkpoint
    let resultURL: URL
    private let destination: ProductionReplayDestination

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
        let expectedParentIdentity = try ProductionReplayParentIdentity(
            environment: environment
        )
        let staging = try ProductionReplayFileSystem.validateNewStagingDestination(
            URL(fileURLWithPath: resultPath)
        )
        guard staging.parent.identity == expectedParentIdentity else {
            throw ProductionReplayDriverError.unsafeResultParent
        }
        self.checkpoint = checkpoint
        resultURL = staging.finalURL
        destination = staging
    }

    /// Assertions run first. The child then writes only its unique staging file, validates
    /// that regular file, and records the completion sentinel last. The parent is solely
    /// responsible for publishing the staging bytes to the caller's final destination.
    func complete(
        resultData: Data,
        afterAssertions assertions: () throws -> Void
    ) throws {
        try assertions()
        try ProductionReplayFileSystem.writeStagingArtifact(
            resultData,
            to: destination
        )
        SubprocessDeadlineGuard.recordVictimCompletion()
    }
}

struct ProductionReplayRunResult: Equatable {
    let outcome: SubprocessDeadlineGuardOutcome
    private let destination: ProductionReplayDestination

    init(
        outcome: SubprocessDeadlineGuardOutcome,
        destination: ProductionReplayDestination
    ) {
        self.outcome = outcome
        self.destination = destination
    }

    var resultURL: URL {
        destination.finalURL
    }

    func resultData() throws -> Data {
        guard outcome == .completed else {
            throw ProductionReplayDriverError.resultUnavailable
        }
        return try ProductionReplayFileSystem.readPublishedArtifact(destination)
    }

    static func == (
        lhs: ProductionReplayRunResult,
        rhs: ProductionReplayRunResult
    ) -> Bool {
        lhs.outcome == rhs.outcome && lhs.resultURL == rhs.resultURL
    }
}

typealias ProductionReplayDeadlineRunner = (
    _ victimFilter: String,
    _ additionalEnvironment: [String: String],
    _ deadlineSeconds: Double,
    _ hostArguments: [String]
) throws -> SubprocessDeadlineGuardOutcome

typealias ProductionReplayArtifactValidator = (Data) throws -> Void
typealias ProductionReplayDeadlineValidator = () throws -> Void

enum ProductionReplayDriver {
    // swiftlint:disable:next function_body_length
    static func run(
        victim: ProductionReplayVictim,
        input: ProductionReplayInput<some ProductionReplayCheckpoint>,
        deadlineSeconds: Double,
        hostArguments: [String] = CommandLine.arguments,
        artifactValidator: ProductionReplayArtifactValidator = { _ in },
        completionDeadlineValidator:
        ProductionReplayDeadlineValidator = {},
        deadlineRunner: ProductionReplayDeadlineRunner = runDeadlineGuard
    ) throws -> ProductionReplayRunResult {
        guard deadlineSeconds.isFinite, deadlineSeconds > 0 else {
            throw ProductionReplayDriverError.invalidDeadline
        }

        let destination = try ProductionReplayFileSystem.validateFinalDestination(
            input.resultURL
        )
        let staging = try ProductionReplayFileSystem.makeStagingDestination(
            for: destination
        )
        defer {
            ProductionReplayFileSystem.removeStagingIfPresent(
                staging,
                parent: destination.parent
            )
        }

        let outcome = try deadlineRunner(
            victim.exactFilter,
            input.environmentVariables(
                stagingResultURL: staging.url,
                parentIdentity: destination.parent.identity
            ),
            deadlineSeconds,
            hostArguments
        )
        guard outcome == .completed else {
            return ProductionReplayRunResult(
                outcome: outcome,
                destination: destination
            )
        }

        try completionDeadlineValidator()
        try ProductionReplayFileSystem.validateStagingArtifact(
            staging,
            parent: destination.parent
        )
        try artifactValidator(
            ProductionReplayFileSystem.readStagingArtifact(
                staging,
                parent: destination.parent
            )
        )
        try completionDeadlineValidator()
        try ProductionReplayFileSystem.publish(
            staging,
            to: destination
        )
        try completionDeadlineValidator()
        return ProductionReplayRunResult(
            outcome: outcome,
            destination: destination
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
