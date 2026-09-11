@testable import ArkhamHorrorShared
import CryptoKit
import Foundation

struct AssignmentReplayCheckpointArtifact: Sendable, Equatable {
    static let maxByteCount = 64 * 1024 * 1024

    let fileURL: URL
    let artifactSHA256: String
    let envelopeSHA256: String
    let checkpointName: String
    let questionVersion: Int
    let playerID: PlayerID
    let promptTag: String
    let promptSHA256: String
    let contractRevision: String
    let sourceGameRevision: String

    static func load(
        from fileURL: URL
    ) throws -> AssignmentReplayCheckpointArtifact {
        do {
            let normalized = try ProductionReplayFileSystem.normalizedFileURL(
                fileURL
            )
            let bytes = try ProductionReplayFileSystem.readVerifiedInput(
                normalized,
                maxByteCount: maxByteCount
            )
            let document = try ContractJSON.decode(
                AssignmentCheckpointDocument.self,
                from: bytes,
                maxByteCount: maxByteCount
            )
            let envelope = document.replayCheckpoint
            let provenance = envelope.provenance
            let checkpoint = provenance.checkpoint
            guard envelope.type == "arkham-replay-checkpoint",
                  provenance.schemaVersion == 1,
                  checkpoint.type == "question",
                  !checkpoint.name.isEmpty,
                  checkpoint.questionVersion > 0,
                  !checkpoint.promptTag.isEmpty,
                  isLowerHex(envelope.envelopeSHA256, count: 64),
                  isLowerHex(checkpoint.promptSHA256, count: 64),
                  isLowerHex(provenance.sourceGameRevision, count: 40),
                  isStrictRevision(provenance.contractRevision)
            else {
                throw ProductionAssignmentReplayError.invalidCheckpointArtifact
            }
            return AssignmentReplayCheckpointArtifact(
                fileURL: normalized,
                artifactSHA256: sha256(bytes),
                envelopeSHA256: envelope.envelopeSHA256,
                checkpointName: checkpoint.name,
                questionVersion: checkpoint.questionVersion,
                playerID: checkpoint.playerID,
                promptTag: checkpoint.promptTag,
                promptSHA256: checkpoint.promptSHA256,
                contractRevision: provenance.contractRevision,
                sourceGameRevision: provenance.sourceGameRevision
            )
        } catch let error as ProductionAssignmentReplayError {
            throw error
        } catch {
            throw ProductionAssignmentReplayError.invalidCheckpointArtifact
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.count == count &&
            value.utf8.allSatisfy {
                (48 ... 57).contains($0) || (97 ... 102).contains($0)
            }
    }

    private static func isStrictRevision(_ value: String) -> Bool {
        !value.isEmpty &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.utf8.allSatisfy { (0x21 ... 0x7E).contains($0) }
    }
}

private struct AssignmentCheckpointDocument: Decodable {
    let replayCheckpoint: AssignmentCheckpointEnvelope

    private enum CodingKeys: String, CodingKey {
        case replayCheckpoint
        case replayProvenance
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard !container.contains(.replayProvenance) else {
            throw ProductionAssignmentReplayError.invalidCheckpointArtifact
        }
        replayCheckpoint = try container.decode(
            AssignmentCheckpointEnvelope.self,
            forKey: .replayCheckpoint
        )
    }
}

private struct AssignmentCheckpointEnvelope: Decodable {
    let type: String
    let provenance: AssignmentCheckpointProvenance
    let envelopeSHA256: String

    private enum CodingKeys: String, CodingKey {
        case type
        case provenance
        case envelopeSHA256 = "envelopeSha256"
    }
}

private struct AssignmentCheckpointProvenance: Decodable {
    let schemaVersion: Int
    let contractRevision: String
    let sourceGameRevision: String
    let checkpoint: AssignmentQuestionCheckpoint

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case contractRevision = "contractSchemaRevision"
        case sourceGameRevision = "sourceGameGitRevision"
        case checkpoint
    }
}

private struct AssignmentQuestionCheckpoint: Decodable {
    let type: String
    let name: String
    let questionVersion: Int
    let playerID: PlayerID
    let promptTag: String
    let promptSHA256: String

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case questionVersion
        case playerID = "playerId"
        case promptTag
        case promptSHA256 = "promptSha256"
    }
}
