@testable import ArkhamHorrorShared
import CryptoKit
import Foundation

struct AssignmentReplayCheckpointFile: Sendable, Equatable {
    static let maximumByteCount = 64 * 1024 * 1024

    let bytes: Data
    let artifactSHA256: String

    init(bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= Self.maximumByteCount else {
            throw ProductionAssignmentReplayError.invalidCheckpointArtifact
        }
        self.bytes = bytes
        artifactSHA256 = Self.sha256(bytes)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct AssignmentReplayValidatedCheckpoint: Equatable, Sendable {
    static let validator = "arkham-replay-server-checkpoint-state-v1"
    static let validationStatus = "validated"

    let validator: String
    let validationStatus: String
    let artifactSHA256: String
    let canonicalEnvelopeSHA256: String
    let backendBuild: AssignmentReplayServerBuildIdentity
    let contractRevision: String
    let gameRevision: String
    let checkpointPlayerID: PlayerID
    let questionVersion: Int
    let promptTag: String
    let promptSHA256: String
    let checkpointGameSHA256: String
    let checkpointQueueSHA256: String

    init(attestation: ProductionAssignmentReplayAttestation) {
        let checkpoint = attestation.validatedCheckpoint
        validator = Self.validator
        validationStatus = Self.validationStatus
        artifactSHA256 = attestation.checkpointSHA256
        canonicalEnvelopeSHA256 = attestation.canonicalEnvelopeSHA256
        backendBuild = attestation.runningServerBuild
        contractRevision = checkpoint.contractSchemaRevision
        gameRevision = attestation.gameGitRevision
        checkpointPlayerID = checkpoint.prompt.playerID
        questionVersion = checkpoint.prompt.questionVersion
        promptTag = checkpoint.prompt.promptTag
        promptSHA256 = checkpoint.prompt.promptSHA256
        checkpointGameSHA256 = checkpoint.checkpointGameSHA256
        checkpointQueueSHA256 = checkpoint.checkpointQueueSHA256
    }
}
