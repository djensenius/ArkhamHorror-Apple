@testable import ArkhamHorrorShared
import Foundation
import Testing

// swiftlint:disable file_length

enum AssignmentReplayCoordinatorCheckpoint: String, ProductionReplayCheckpoint {
    case bothCases = "assignment-replay-both-cases"
}

struct AssignmentReplayCoordinatorCaseReceipt: Codable, Equatable, Sendable {
    let caseName: String
    let fileName: String
    let gameID: GameID
    let playerID: PlayerID
    let evidenceSHA256: String
}

struct AssignmentReplayCoordinatorManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let appleRevision: String
    let checkpointArtifactSHA256: String
    let cases: [AssignmentReplayCoordinatorCaseReceipt]

    func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  appleRevision,
                  count: 40
              ),
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  checkpointArtifactSHA256,
                  count: 64
              ),
              cases.map(\.caseName) ==
              ProductionAssignmentReplayCheckpoint.allCases.map(\.rawValue),
              cases.map(\.fileName) == [
                  AssignmentReplayCoordinatorDriver.damageEvidenceName,
                  AssignmentReplayCoordinatorDriver.horrorEvidenceName,
              ],
              Set(cases.map(\.gameID)).count == cases.count,
              Set(cases.map(\.playerID)).count == cases.count,
              cases.allSatisfy({
                  ProductionAssignmentReplayConfiguration.isLowercaseHex(
                      $0.evidenceSHA256,
                      count: 64
                  )
              })
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
    }
}

// swiftlint:disable:next type_name
struct AssignmentReplayCoordinatorManifestArtifact: Codable, Equatable, Sendable {
    let manifest: AssignmentReplayCoordinatorManifest
    let manifestCanonicalSHA256: String

    init(manifest: AssignmentReplayCoordinatorManifest) throws {
        try manifest.validate()
        self.manifest = manifest
        manifestCanonicalSHA256 =
            try ProductionAssignmentReplayCanonicalJSON.digest(manifest)
    }

    func validatedData() throws -> Data {
        try manifest.validate()
        let digest =
            try ProductionAssignmentReplayCanonicalJSON.digest(manifest)
        guard manifestCanonicalSHA256 == digest else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
        return try ContractJSON.encode(self)
    }

    static func decodeAndValidate(
        _ data: Data
    ) throws -> AssignmentReplayCoordinatorManifestArtifact {
        let artifact = try ContractJSON.decode(
            AssignmentReplayCoordinatorManifestArtifact.self,
            from: data
        )
        guard try artifact.validatedData() == data else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
        return artifact
    }
}

typealias AssignmentReplayCoordinatorCaseRunner =
    @MainActor @Sendable (
        ProductionAssignmentReplayConfiguration
    ) async throws -> ProductionAssignmentReplayEvidence

// swiftlint:disable:next type_body_length
private enum AssignmentReplayCoordinatorEngine {
    private struct PreparedCase {
        let checkpoint: ProductionAssignmentReplayCheckpoint
        let gameID: GameID
        let playerID: PlayerID
        let attestation: ProductionAssignmentReplayAttestation
    }

    @MainActor
    // swiftlint:disable:next function_body_length
    static func run(
        child: ProductionAssignmentReplayCoordinatorChildInvocation,
        backend: any AssignmentReplayCoordinatorBackend,
        caseRunner: AssignmentReplayCoordinatorCaseRunner
    ) async throws -> AssignmentReplayCoordinatorManifestArtifact {
        _ = try child.deadline.remainingSeconds()
        let input = child.invocation
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
        let token = try validatedToken(tokenHandle.readOnce())

        var succeeded = false
        defer {
            if !succeeded {
                for name in [
                    AssignmentReplayCoordinatorDriver.damageEvidenceName,
                    AssignmentReplayCoordinatorDriver.horrorEvidenceName,
                ] {
                    try? ProductionReplayFileSystem.removeOwnedFile(
                        named: name,
                        from: output
                    )
                }
            }
        }

        let damagePreparation = try await prepareCase(
            .damageFirstThenRemainingHorror,
            checkpoint: checkpoint,
            token: token,
            child: child,
            backend: backend
        )
        let horrorPreparation = try await prepareCase(
            .horrorFirstThenRemainingDamage,
            checkpoint: checkpoint,
            token: token,
            child: child,
            backend: backend
        )
        guard damagePreparation.gameID != horrorPreparation.gameID
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .duplicateImportedGame
        }
        guard damagePreparation.playerID != horrorPreparation.playerID
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .duplicateImportedPlayer
        }
        guard damagePreparation.attestation.checkpointValidation ==
            horrorPreparation.attestation.checkpointValidation,
            damagePreparation.attestation.serverBuild ==
            horrorPreparation.attestation.serverBuild
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .checkpointAuthorityMismatch
        }
        _ = try child.deadline.remainingSeconds()

        let damage = try await executeCase(
            damagePreparation,
            token: token,
            child: child,
            output: output,
            caseRunner: caseRunner
        )
        let horror = try await executeCase(
            horrorPreparation,
            token: token,
            child: child,
            output: output,
            caseRunner: caseRunner
        )

        let manifest = AssignmentReplayCoordinatorManifest(
            schemaVersion:
            AssignmentReplayCoordinatorManifest.schemaVersion,
            appleRevision: child.appleRevision,
            checkpointArtifactSHA256: checkpoint.artifactSHA256,
            cases: [damage, horror]
        )
        let artifact = try AssignmentReplayCoordinatorManifestArtifact(
            manifest: manifest
        )
        try artifact.manifest.validate()
        guard try ProductionReplayFileSystem.listOwnedDirectoryNames(output) ==
            [
                AssignmentReplayCoordinatorDriver.damageEvidenceName,
                AssignmentReplayCoordinatorDriver.horrorEvidenceName,
            ]
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
        _ = try child.deadline.remainingSeconds()
        succeeded = true
        return artifact
    }

    @MainActor
    private static func prepareCase(
        _ checkpointCase: ProductionAssignmentReplayCheckpoint,
        checkpoint: AssignmentReplayCheckpointFile,
        token: String,
        child: ProductionAssignmentReplayCoordinatorChildInvocation,
        backend: any AssignmentReplayCoordinatorBackend
    ) async throws -> PreparedCase {
        _ = try child.deadline.remainingSeconds()
        let input = child.invocation
        let gameID = try await backend.importCheckpoint(
            checkpoint,
            investigatorID: input.investigatorID,
            profile: input.serverProfile,
            token: token,
            deadline: child.deadline
        )
        _ = try child.deadline.remainingSeconds()
        let game = try await backend.getGame(
            gameID,
            profile: input.serverProfile,
            token: token,
            deadline: child.deadline
        )
        _ = try child.deadline.remainingSeconds()
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
        _ = try child.deadline.remainingSeconds()
        try attestation.validate(request: attestationRequest)
        guard game.game.git == attestation.gameRevision else {
            throw ProductionAssignmentReplayCoordinatorError
                .importedGameIdentityMismatch
        }
        return PreparedCase(
            checkpoint: checkpointCase,
            gameID: gameID,
            playerID: playerID,
            attestation: attestation
        )
    }

    @MainActor
    // swiftlint:disable:next function_body_length
    private static func executeCase(
        _ prepared: PreparedCase,
        token: String,
        child: ProductionAssignmentReplayCoordinatorChildInvocation,
        output: ProductionReplayOwnedDirectory,
        caseRunner: AssignmentReplayCoordinatorCaseRunner
    ) async throws -> AssignmentReplayCoordinatorCaseReceipt {
        _ = try child.deadline.remainingSeconds()
        let input = child.invocation
        let configuration = try ProductionAssignmentReplayConfiguration(
            checkpoint: prepared.checkpoint,
            deadline: child.deadline,
            serverProfile: input.serverProfile,
            authToken: token,
            promptIdentity: ProductionAssignmentReplayPromptIdentity(
                gameID: prepared.gameID,
                ownerID: prepared.playerID,
                enemyID: input.enemyID,
                investigatorID: input.investigatorID
            ),
            expectedAppleRevision: child.appleRevision,
            expectedContractRevision: input.expectedContractRevision,
            expectedCatalogRevision: input.expectedCatalogRevision,
            attestation: prepared.attestation
        )
        let evidence = try await caseRunner(configuration)
        _ = try child.deadline.remainingSeconds()
        try evidence.validate(
            configuration: configuration,
            attestation: prepared.attestation
        )
        let data = try AssignmentReplayEvidenceArtifact(
            evidence: evidence
        ).validatedData()
        let fileName = fileName(for: prepared.checkpoint)
        try ProductionReplayFileSystem.writeOwnedFile(
            data,
            named: fileName,
            in: output
        )
        let persisted = try ProductionReplayFileSystem.readOwnedFile(
            named: fileName,
            in: output,
            maxByteCount: 1024 * 1024
        )
        guard persisted == data else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
        let decoded = try AssignmentReplayEvidenceArtifact
            .decodeAndValidate(persisted)
        try decoded.evidence.validate(
            configuration: configuration,
            attestation: prepared.attestation
        )
        _ = try child.deadline.remainingSeconds()
        return AssignmentReplayCoordinatorCaseReceipt(
            caseName: prepared.checkpoint.rawValue,
            fileName: fileName,
            gameID: prepared.gameID,
            playerID: prepared.playerID,
            evidenceSHA256: LocaleCatalogLoader.sha256Hex(persisted)
        )
    }

    private static func fileName(
        for checkpoint: ProductionAssignmentReplayCheckpoint
    ) -> String {
        switch checkpoint {
        case .damageFirstThenRemainingHorror:
            AssignmentReplayCoordinatorDriver.damageEvidenceName
        case .horrorFirstThenRemainingDamage:
            AssignmentReplayCoordinatorDriver.horrorEvidenceName
        }
    }

    private static func validatedToken(_ bytes: Data) throws -> String {
        var tokenBytes = bytes
        if tokenBytes.last == 0x0A {
            tokenBytes.removeLast()
        }
        guard (1 ... 4096).contains(tokenBytes.count),
              tokenBytes.allSatisfy({ (0x21 ... 0x7E).contains($0) }),
              let token = String(data: tokenBytes, encoding: .ascii)
        else {
            throw AssignmentReplayConfigurationError.invalidAuthToken
        }
        return token
    }
}

enum ProductionAssignmentReplayCoordinator {
    @MainActor
    static func run(
        child: ProductionAssignmentReplayCoordinatorChildInvocation
    ) async throws -> AssignmentReplayCoordinatorManifestArtifact {
        try await AssignmentReplayCoordinatorEngine.run(
            child: child,
            backend: ProductionAssignmentReplayBackend(),
            caseRunner: { configuration in
                try await AssignmentContinuationReplayRunner.run(
                    configuration: configuration
                )
            }
        )
    }
}

// swiftlint:disable:next type_name
enum AssignmentReplayCoordinatorSelfTestHarness {
    @MainActor
    static func run(
        child: ProductionAssignmentReplayCoordinatorChildInvocation,
        backend: any AssignmentReplayCoordinatorBackend,
        caseRunner: AssignmentReplayCoordinatorCaseRunner
    ) async throws -> AssignmentReplayCoordinatorManifestArtifact {
        try await AssignmentReplayCoordinatorEngine.run(
            child: child,
            backend: backend,
            caseRunner: caseRunner
        )
    }
}

enum AssignmentReplayCoordinatorDriver {
    static let damageEvidenceName = "damage-first.json"
    static let horrorEvidenceName = "horror-first.json"
    static let completionManifestName =
        ".production-assignment-replay-completion.json"

    static func victim() throws -> ProductionReplayVictim {
        try ProductionReplayVictim(
            moduleName: "ArkhamHorrorSharedTests",
            suiteName: "AssignmentReplayCoordinatorVictimSuite",
            functionName: "runProductionAssignmentReplayCoordinator"
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
    ) throws -> AssignmentReplayCoordinatorManifest {
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
        let manifestURL = output.fileURL(
            named: completionManifestName
        )
        let input = try ProductionReplayInput(
            checkpoint: AssignmentReplayCoordinatorCheckpoint.bothCases,
            resultURL: manifestURL,
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
                _ = try AssignmentReplayCoordinatorManifestArtifact
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
        _ = try deadline.remainingSeconds()
        let resultData = try result.resultData()
        _ = try deadline.remainingSeconds()
        let manifestArtifact =
            try AssignmentReplayCoordinatorManifestArtifact.decodeAndValidate(
                resultData
            )
        _ = try deadline.remainingSeconds()
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
            [damageEvidenceName, horrorEvidenceName]
        else {
            throw ProductionAssignmentReplayCoordinatorError
                .outputValidationFailed
        }
        _ = try deadline.remainingSeconds()
        succeeded = true
        return manifestArtifact.manifest
    }

    private static func verifyOutputs(
        _ manifest: AssignmentReplayCoordinatorManifest,
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
        for receipt in manifest.cases {
            _ = try deadline.remainingSeconds()
            let data = try ProductionReplayFileSystem.readOwnedFile(
                named: receipt.fileName,
                in: output,
                maxByteCount: 1024 * 1024
            )
            guard LocaleCatalogLoader.sha256Hex(data) ==
                receipt.evidenceSHA256
            else {
                throw ProductionAssignmentReplayCoordinatorError
                    .outputValidationFailed
            }
            let artifact = try AssignmentReplayEvidenceArtifact
                .decodeAndValidate(data)
            guard artifact.evidence.checkpoint.caseName == receipt.caseName,
                  artifact.evidence.checkpoint.artifactSHA256 ==
                  manifest.checkpointArtifactSHA256,
                  artifact.evidence.source.gameID == receipt.gameID,
                  artifact.evidence.source.playerID == receipt.playerID,
                  artifact.evidence.revisions.apple ==
                  expectedAppleRevision
            else {
                throw ProductionAssignmentReplayCoordinatorError
                    .outputValidationFailed
            }
        }
        _ = try deadline.remainingSeconds()
    }
}

@MainActor
@Suite("Production assignment replay coordinator victim")
struct AssignmentReplayCoordinatorVictimSuite {
    @Test("Run both authoritative assignment replay cases")
    func runProductionAssignmentReplayCoordinator() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[ProductionReplayEnvironmentKey.checkpoint] != nil
        else {
            return
        }
        let context =
            try ProductionReplayChildContext<
                AssignmentReplayCoordinatorCheckpoint
            >(environment: environment)
        let child =
            try ProductionAssignmentReplayCoordinatorChildInvocation.parse(
                environment: environment
            )
        let artifact = try await ProductionAssignmentReplayCoordinator.run(
            child: child
        )
        let data = try artifact.validatedData()
        try context.complete(resultData: data) {
            try artifact.manifest.validate()
        }
    }
}

@Suite("Production assignment replay coordinator driver")
struct AssignmentReplayCoordinatorDriverSuite {
    @Test("Run configured production assignment replay coordinator")
    func runConfiguredProductionAssignmentReplayCoordinator() throws {
        guard let invocation =
            try ProductionAssignmentReplayCoordinatorInvocation.parse()
        else {
            return
        }
        _ = try AssignmentReplayCoordinatorDriver.run(
            invocation: invocation
        )
    }
}
