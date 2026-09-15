@testable import ArkhamHorrorShared
import Foundation
import Testing

// swiftlint:disable file_length
// swiftlint:disable opening_brace
enum GatheringActReplayCoordinatorCheckpoint:
    String,
    ProductionReplayCheckpoint
{
    case q34 = "gathering-act-advance"
}

struct GatheringActReplayCoordinatorReceipt:
    Codable,
    Equatable,
    Sendable
{
    let caseName: String
    let fileName: String
    let gameID: GameID
    let playerID: PlayerID
    let evidenceSHA256: String
}

struct GatheringActReplayCoordinatorManifest:
    Codable,
    Equatable,
    Sendable
{
    static let schemaVersion = 1

    let schemaVersion: Int
    let scenario: String
    let appleRevision: String
    let checkpointArtifactSHA256: String
    let receipt: GatheringActReplayCoordinatorReceipt

    func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              scenario ==
              ProductionAssignmentReplayScenario
              .gatheringActAdvance.rawValue,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  appleRevision,
                  count: 40
              ),
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  checkpointArtifactSHA256,
                  count: 64
              ),
              receipt.caseName == scenario,
              receipt.fileName ==
              GatheringActReplayCoordinatorDriver.evidenceName,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  receipt.evidenceSHA256,
                  count: 64
              )
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
    }
}

// swiftlint:disable:next type_name
struct GatheringActReplayCoordinatorManifestArtifact:
    Codable,
    Equatable,
    Sendable
{
    // swiftlint:enable opening_brace
    let manifest: GatheringActReplayCoordinatorManifest
    let manifestCanonicalSHA256: String

    init(manifest: GatheringActReplayCoordinatorManifest) throws {
        try manifest.validate()
        self.manifest = manifest
        manifestCanonicalSHA256 =
            try ProductionAssignmentReplayCanonicalJSON.digest(manifest)
    }

    func validatedData() throws -> Data {
        try manifest.validate()
        guard try manifestCanonicalSHA256 ==
            (ProductionAssignmentReplayCanonicalJSON.digest(manifest))
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
        return try ContractJSON.encode(self)
    }

    static func decodeAndValidate(
        _ data: Data
    ) throws -> GatheringActReplayCoordinatorManifestArtifact {
        let artifact = try ContractJSON.decode(
            GatheringActReplayCoordinatorManifestArtifact.self,
            from: data
        )
        guard try artifact.validatedData() == data else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
        return artifact
    }
}

typealias GatheringActReplayCoordinatorCaseRunner =
    @MainActor @Sendable (
        ProductionGatheringActReplayConfiguration
    ) async throws -> ProductionGatheringActReplayEvidence

private enum GatheringActReplayCoordinatorEngine {
    @MainActor
    // swiftlint:disable:next function_body_length
    static func run(
        child: ProductionAssignmentReplayCoordinatorChildInvocation,
        backend: any AssignmentReplayCoordinatorBackend,
        caseRunner: GatheringActReplayCoordinatorCaseRunner
    ) async throws -> GatheringActReplayCoordinatorManifestArtifact {
        _ = try child.deadline.remainingSeconds()
        let input = child.invocation
        guard input.scenario == .gatheringActAdvance else {
            throw ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(
                    AssignmentReplayCoordinatorEnvironmentKey.scenario
                )
        }
        let output = try ProductionReplayFileSystem.openPrivateDirectory(
            input.outputDirectoryURL,
            expectedIdentity: child.outputIdentity
        )
        guard try ProductionReplayFileSystem.listOwnedDirectoryNames(output)
            .isEmpty
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
        let checkpointHandle = try ProductionReplayFileSystem.openVerifiedInput(
            input.checkpointURL,
            maxByteCount: AssignmentReplayCheckpointFile.maximumByteCount
        )
        let tokenHandle = try ProductionReplayFileSystem.openVerifiedInput(
            input.tokenURL,
            maxByteCount: 4097,
            permission: .ownerReadWriteOnly
        )
        let checkpoint = try AssignmentReplayCheckpointFile(
            bytes: checkpointHandle.readOnce()
        )
        let token = try ProductionReplayCredentialValidator.validatedToken(
            tokenHandle.readOnce()
        )

        var succeeded = false
        defer {
            if !succeeded {
                try? ProductionReplayFileSystem.removeOwnedFile(
                    named: GatheringActReplayCoordinatorDriver.evidenceName,
                    from: output
                )
            }
        }

        _ = try child.deadline.remainingSeconds()
        let gameID = try await backend.importCheckpoint(
            checkpoint,
            investigatorID: input.investigatorID,
            profile: input.serverProfile,
            token: token,
            deadline: child.deadline
        )
        let game = try await backend.getGame(
            gameID,
            profile: input.serverProfile,
            token: token,
            deadline: child.deadline
        )
        guard game.game.id == gameID else {
            throw ProductionAssignmentReplayCoordinatorError
                .importedGameIdentityMismatch
        }
        guard let playerID = game.playerID else {
            throw ProductionAssignmentReplayCoordinatorError
                .importedPlayerMissing
        }
        let attestationRequest = AssignmentReplayAttestationRequest(
            serverProfile: input.serverProfile,
            authToken: token,
            gameID: gameID,
            playerID: playerID,
            investigatorID: input.investigatorID,
            checkpointArtifactSHA256: checkpoint.artifactSHA256
        )
        let attestation = try await backend.fetchAttestation(
            attestationRequest,
            deadline: child.deadline
        )
        try attestation.validate(request: attestationRequest)
        guard game.game.git == attestation.gameRevision else {
            throw ProductionAssignmentReplayCoordinatorError
                .importedGameIdentityMismatch
        }
        let configuration = try ProductionGatheringActReplayConfiguration(
            deadline: child.deadline,
            serverProfile: input.serverProfile,
            authToken: token,
            promptIdentity: ProductionGatheringActReplayPromptIdentity(
                gameID: gameID,
                ownerID: playerID,
                investigatorID: input.investigatorID
            ),
            expectedAppleRevision: child.appleRevision,
            expectedContractRevision: input.expectedContractRevision,
            expectedCatalogRevision: input.expectedCatalogRevision,
            attestation: attestation
        )

        let evidence = try await caseRunner(configuration)
        _ = try child.deadline.remainingSeconds()
        try evidence.validate(
            configuration: configuration,
            attestation: attestation
        )
        let data = try GatheringActReplayEvidenceArtifact(
            evidence: evidence
        ).validatedData()
        try ProductionReplayFileSystem.writeOwnedFile(
            data,
            named: GatheringActReplayCoordinatorDriver.evidenceName,
            in: output
        )
        let persisted = try ProductionReplayFileSystem.readOwnedFile(
            named: GatheringActReplayCoordinatorDriver.evidenceName,
            in: output,
            maxByteCount: 2 * 1024 * 1024
        )
        guard persisted == data else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
        let decoded = try GatheringActReplayEvidenceArtifact
            .decodeAndValidate(persisted)
        try decoded.evidence.validate(
            configuration: configuration,
            attestation: attestation
        )

        let manifest = GatheringActReplayCoordinatorManifest(
            schemaVersion:
            GatheringActReplayCoordinatorManifest.schemaVersion,
            scenario:
            ProductionAssignmentReplayScenario
                .gatheringActAdvance.rawValue,
            appleRevision: child.appleRevision,
            checkpointArtifactSHA256: checkpoint.artifactSHA256,
            receipt: GatheringActReplayCoordinatorReceipt(
                caseName:
                ProductionAssignmentReplayScenario
                    .gatheringActAdvance.rawValue,
                fileName:
                GatheringActReplayCoordinatorDriver.evidenceName,
                gameID: gameID,
                playerID: playerID,
                evidenceSHA256:
                LocaleCatalogLoader.sha256Hex(persisted)
            )
        )
        let artifact = try GatheringActReplayCoordinatorManifestArtifact(
            manifest: manifest
        )
        guard try ProductionReplayFileSystem.listOwnedDirectoryNames(output) ==
            [GatheringActReplayCoordinatorDriver.evidenceName]
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
        _ = try child.deadline.remainingSeconds()
        succeeded = true
        return artifact
    }
}

enum ProductionGatheringActReplayCoordinator {
    @MainActor
    static func run(
        child: ProductionAssignmentReplayCoordinatorChildInvocation
    ) async throws -> GatheringActReplayCoordinatorManifestArtifact {
        try await GatheringActReplayCoordinatorEngine.run(
            child: child,
            backend: ProductionAssignmentReplayBackend(),
            caseRunner: { configuration in
                try await ProductionGatheringActReplayRunner.run(
                    configuration: configuration
                )
            }
        )
    }
}

// swiftlint:disable:next type_name
enum GatheringActReplayCoordinatorSelfTestHarness {
    @MainActor
    static func run(
        child: ProductionAssignmentReplayCoordinatorChildInvocation,
        backend: any AssignmentReplayCoordinatorBackend,
        caseRunner: GatheringActReplayCoordinatorCaseRunner
    ) async throws -> GatheringActReplayCoordinatorManifestArtifact {
        try await GatheringActReplayCoordinatorEngine.run(
            child: child,
            backend: backend,
            caseRunner: caseRunner
        )
    }
}

enum GatheringActReplayCoordinatorDriver {
    static let evidenceName = "gathering-act-advance.json"
    static let completionManifestName =
        ".production-gathering-act-replay-completion.json"

    static func victim() throws -> ProductionReplayVictim {
        try ProductionReplayVictim(
            moduleName: "ArkhamHorrorSharedTests",
            suiteName: "GatheringActReplayCoordinatorVictimSuite",
            functionName: "runProductionGatheringActReplayCoordinator"
        )
    }

    // swiftlint:disable:next function_body_length
    static func run(
        invocation: ProductionAssignmentReplayCoordinatorInvocation,
        hostArguments: [String] = CommandLine.arguments,
        appleRevisionProvider: () throws -> String = {
            try ProductionAssignmentReplayGitRevision.current()
        },
        deadlineRunner: ProductionReplayDeadlineRunner = {
            try SubprocessDeadlineGuard.runFiltered(
                victimFilter: $0,
                additionalEnvironment: $1,
                deadlineSeconds: $2,
                hostArguments: $3
            )
        }
    ) throws -> GatheringActReplayCoordinatorManifest {
        guard invocation.scenario == .gatheringActAdvance else {
            throw ProductionAssignmentReplayCoordinatorError
                .invalidEnvironmentValue(
                    AssignmentReplayCoordinatorEnvironmentKey.scenario
                )
        }
        let appleRevision = try appleRevisionProvider()
        let output = try ProductionReplayFileSystem.createPrivateDirectory(
            invocation.outputDirectoryURL
        )
        var succeeded = false
        defer {
            if !succeeded {
                try? ProductionReplayFileSystem.removeOwnedDirectory(output)
            }
        }
        let deadline = AssignmentReplayCoordinatorDeadline(
            secondsFromNow: invocation.deadlineSeconds
        )
        let input = try ProductionReplayInput(
            checkpoint: GatheringActReplayCoordinatorCheckpoint.q34,
            resultURL: output.fileURL(named: completionManifestName),
            additionalEnvironment: invocation.childEnvironment(
                observedAppleRevision: appleRevision,
                outputIdentity: output.identity,
                deadline: deadline
            )
        )
        let result = try ProductionReplayDriver.run(
            victim: victim(),
            input: input,
            deadlineSeconds: deadline.remainingSeconds(),
            hostArguments: hostArguments,
            artifactValidator: {
                _ = try GatheringActReplayCoordinatorManifestArtifact
                    .decodeAndValidate($0)
            },
            completionDeadlineValidator: {
                _ = try deadline.remainingSeconds()
            },
            deadlineRunner: deadlineRunner
        )
        guard result.outcome == .completed else {
            throw ProductionAssignmentReplayCoordinatorError.unsupportedHost
        }
        let manifestArtifact =
            try GatheringActReplayCoordinatorManifestArtifact
                .decodeAndValidate(result.resultData())
        try verifyOutputs(
            manifestArtifact.manifest,
            expectedAppleRevision: appleRevision,
            output: output,
            deadline: deadline
        )
        try ProductionReplayFileSystem.removeOwnedFile(
            named: completionManifestName,
            from: output
        )
        guard try ProductionReplayFileSystem.listOwnedDirectoryNames(output) ==
            [evidenceName]
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
        _ = try deadline.remainingSeconds()
        succeeded = true
        return manifestArtifact.manifest
    }

    private static func verifyOutputs(
        _ manifest: GatheringActReplayCoordinatorManifest,
        expectedAppleRevision: String,
        output: ProductionReplayOwnedDirectory,
        deadline: AssignmentReplayCoordinatorDeadline
    ) throws {
        _ = try deadline.remainingSeconds()
        try manifest.validate()
        guard manifest.appleRevision == expectedAppleRevision else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
        let data = try ProductionReplayFileSystem.readOwnedFile(
            named: manifest.receipt.fileName,
            in: output,
            maxByteCount: 2 * 1024 * 1024
        )
        guard LocaleCatalogLoader.sha256Hex(data) ==
            manifest.receipt.evidenceSHA256
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
        let artifact = try GatheringActReplayEvidenceArtifact
            .decodeAndValidate(data)
        guard artifact.evidence.gameID == manifest.receipt.gameID,
              artifact.evidence.playerID == manifest.receipt.playerID,
              artifact.evidence.attestation.checkpointSHA256 ==
              manifest.checkpointArtifactSHA256,
              artifact.evidence.revisions.apple ==
              expectedAppleRevision
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
        _ = try deadline.remainingSeconds()
    }
}

@MainActor
@Suite("Production Gathering act replay coordinator victim")
struct GatheringActReplayCoordinatorVictimSuite {
    @Test("Run authoritative Gathering act replay")
    func runProductionGatheringActReplayCoordinator() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[ProductionReplayEnvironmentKey.checkpoint] != nil
        else {
            return
        }
        let context =
            try ProductionReplayChildContext<
                GatheringActReplayCoordinatorCheckpoint
            >(environment: environment)
        let child =
            try ProductionAssignmentReplayCoordinatorChildInvocation.parse(
                environment: environment
            )
        let artifact = try await ProductionGatheringActReplayCoordinator.run(
            child: child
        )
        let data = try artifact.validatedData()
        try context.complete(resultData: data) {
            try artifact.manifest.validate()
        }
    }
}
