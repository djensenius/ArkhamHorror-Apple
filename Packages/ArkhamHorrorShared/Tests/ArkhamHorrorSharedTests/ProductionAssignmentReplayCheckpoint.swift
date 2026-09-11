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

struct AssignmentReplayValidatedCheckpoint: Codable, Equatable, Sendable {
    static let validator = "arkham-replay-checkpoint-envelope-v1"
    static let validationStatus = "validated"

    let validator: String
    let validationStatus: String
    let artifactSHA256: String
    let canonicalEnvelopeSHA256: String
    let replayBuild: AssignmentReplayServerBuildIdentity
    let contractRevision: String
    let sourceGameRevision: String
    let checkpointName: String
    let checkpointPlayerID: PlayerID
    let questionVersion: Int
    let promptTag: String
    let promptSHA256: String

    private enum CodingKeys: String, CodingKey {
        case validator
        case validationStatus
        case artifactSHA256 = "artifactSha256"
        case canonicalEnvelopeSHA256 = "canonicalEnvelopeSha256"
        case replayBuild
        case contractRevision
        case sourceGameRevision
        case checkpointName
        case checkpointPlayerID = "checkpointPlayerId"
        case questionVersion
        case promptTag
        case promptSHA256 = "promptSha256"
    }

    func validate(runningServerBuild: AssignmentReplayServerBuildIdentity) throws {
        try replayBuild.validate()
        guard validator == Self.validator,
              validationStatus == Self.validationStatus,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  artifactSHA256,
                  count: 64
              ),
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  canonicalEnvelopeSHA256,
                  count: 64
              ),
              replayBuild == runningServerBuild,
              contractRevision ==
              ContractPin.current.supportedSchemaRevision.description,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  sourceGameRevision,
                  count: 40
              ),
              !checkpointName.isEmpty,
              checkpointName ==
              checkpointName.trimmingCharacters(in: .whitespacesAndNewlines),
              questionVersion > 0,
              questionVersion < Int.max,
              promptTag == BasicChoiceQuestionKind.questionWithSource.rawValue,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  promptSHA256,
                  count: 64
              )
        else {
            throw ProductionAssignmentReplayError.serverAttestationMismatch
        }
    }
}
