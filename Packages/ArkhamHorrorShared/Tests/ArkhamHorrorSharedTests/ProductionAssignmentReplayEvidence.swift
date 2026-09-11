@testable import ArkhamHorrorShared
import Foundation

struct ProductionAssignmentReplaySourceEvidence: Codable, Equatable, Sendable {
    let gameID: GameID
    let playerID: PlayerID
    let promptTag: String
    let sourceTag: String
    let enemyID: EnemyID
    let investigatorID: InvestigatorID
    let promptVersion: Int
    let promptCanonicalSHA256: String
    let selectedAssignment: String
    let sourceIndex: Int
}

struct AssignmentReplayControllerEvidence: Codable, Equatable, Sendable {
    let jumpToActivePromptHandled: Bool
    let focusAfterJump: String
    let movedToSelectedSourceIndex: Bool
    let focusBeforePrimaryAction: String
    let primaryActionHandled: Bool
}

struct AssignmentReplayNextPromptEvidence: Codable, Equatable, Sendable {
    let promptTag: String
    let sourceTag: String
    let assignment: String
    let version: Int
    let canonicalSHA256: String
}

struct AssignmentReplayRevisionEvidence: Codable, Equatable, Sendable {
    let backend: String
    let apple: String
    let contract: ContractRevision
    let catalog: String
}

struct ProductionAssignmentReplayEvidence: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0.0"

    let schemaVersion: String
    let checkpoint: String
    let source: ProductionAssignmentReplaySourceEvidence
    let answer: BasicChoiceAnswer
    let controller: AssignmentReplayControllerEvidence
    let assignmentBefore: AssignmentReplayFields
    let assignmentAfter: AssignmentReplayFields
    let assignmentDelta: AssignmentReplayFields
    let nextPrompt: AssignmentReplayNextPromptEvidence
    let revisions: AssignmentReplayRevisionEvidence

    func validateSemantics() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProductionAssignmentReplayEvidenceError.invalidSchemaVersion
        }
        guard let checkpoint = ProductionAssignmentReplayCheckpoint(rawValue: checkpoint)
        else {
            throw ProductionAssignmentReplayEvidenceError.invalidCheckpoint
        }
        try validateSource(checkpoint: checkpoint)
        try validateAnswer()
        try validateController()
        try validateAssignment(checkpoint: checkpoint)
        try validateNextPrompt(checkpoint: checkpoint)
        try validateRevisions()
    }

    private func validateSource(
        checkpoint: ProductionAssignmentReplayCheckpoint
    ) throws {
        guard source.promptTag == BasicChoiceQuestionKind.questionWithSource.rawValue,
              source.sourceTag == "EnemyAttackSource",
              source.promptVersion >= 0,
              source.promptVersion < Int.max,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  source.promptCanonicalSHA256,
                  count: 64
              ),
              source.selectedAssignment
              == checkpoint.selectedAssignmentKind.productionReplayName,
              source.sourceIndex == checkpoint.sourceIndex
        else {
            throw ProductionAssignmentReplayEvidenceError.invalidSource
        }
    }

    private func validateAnswer() throws {
        guard answer == BasicChoiceAnswer(
            choice: source.sourceIndex,
            playerID: source.playerID,
            questionVersion: source.promptVersion
        ) else {
            throw ProductionAssignmentReplayEvidenceError.invalidAnswer
        }
    }

    private func validateController() throws {
        guard controller.jumpToActivePromptHandled,
              controller.focusAfterJump == BoardFocusID.promptChoice(0).rawValue,
              controller.movedToSelectedSourceIndex == (source.sourceIndex != 0),
              controller.focusBeforePrimaryAction
              == BoardFocusID.promptChoice(source.sourceIndex).rawValue,
              controller.primaryActionHandled
        else {
            throw ProductionAssignmentReplayEvidenceError.invalidController
        }
    }

    private func validateAssignment(
        checkpoint: ProductionAssignmentReplayCheckpoint
    ) throws {
        guard assignmentBefore == checkpoint.assignmentBefore,
              assignmentAfter == checkpoint.assignmentAfter,
              assignmentDelta == checkpoint.assignmentDelta,
              assignmentAfter.subtracting(assignmentBefore) == assignmentDelta
        else {
            throw ProductionAssignmentReplayEvidenceError.invalidAssignment
        }
    }

    private func validateNextPrompt(
        checkpoint: ProductionAssignmentReplayCheckpoint
    ) throws {
        guard nextPrompt.promptTag
            == BasicChoiceQuestionKind.questionWithSource.rawValue,
            nextPrompt.sourceTag == "EnemyAttackSource",
            nextPrompt.assignment == checkpoint.nextAssignmentKind.productionReplayName,
            nextPrompt.version == source.promptVersion + 1,
            ProductionAssignmentReplayConfiguration.isLowercaseHex(
                nextPrompt.canonicalSHA256,
                count: 64
            )
        else {
            throw ProductionAssignmentReplayEvidenceError.invalidNextPrompt
        }
    }

    private func validateRevisions() throws {
        guard ProductionAssignmentReplayConfiguration.isLowercaseHex(
            revisions.backend,
            count: 40
        ),
            ProductionAssignmentReplayConfiguration.isLowercaseHex(
                revisions.apple,
                count: 40
            ),
            revisions.backend == ContractPin.current.backendCommit,
            revisions.contract == ContractPin.current.supportedSchemaRevision,
            LocaleCatalogGrammar.isCatalogRevision(revisions.catalog)
        else {
            throw ProductionAssignmentReplayEvidenceError.invalidRevisions
        }
    }

    func validate(
        configuration: ProductionAssignmentReplayConfiguration
    ) throws {
        try validateSemantics()
        guard checkpoint == configuration.checkpoint.rawValue,
              source.gameID == configuration.promptIdentity.gameID,
              source.playerID == configuration.promptIdentity.ownerID,
              source.enemyID == configuration.promptIdentity.enemyID,
              source.investigatorID
              == configuration.promptIdentity.investigatorID,
              source.promptVersion == configuration.expectedPromptVersion,
              source.promptCanonicalSHA256
              == configuration.expectedPromptDigest,
              revisions.backend == configuration.expectedBackendRevision,
              revisions.apple == configuration.expectedAppleRevision,
              revisions.contract == configuration.expectedContractRevision,
              revisions.catalog == configuration.expectedCatalogRevision
        else {
            throw ProductionAssignmentReplayEvidenceError.configurationMismatch
        }
    }
}

struct AssignmentReplayEvidenceArtifact: Codable, Equatable, Sendable {
    let evidence: ProductionAssignmentReplayEvidence
    let evidenceCanonicalSHA256: String

    init(evidence: ProductionAssignmentReplayEvidence) throws {
        try evidence.validateSemantics()
        self.evidence = evidence
        evidenceCanonicalSHA256 =
            try ProductionAssignmentReplayCanonicalJSON.digest(evidence)
    }

    func validatedData() throws -> Data {
        try evidence.validateSemantics()
        let digest = try ProductionAssignmentReplayCanonicalJSON.digest(evidence)
        guard evidenceCanonicalSHA256 == digest
        else {
            throw ProductionAssignmentReplayEvidenceError.digestMismatch
        }
        return try ContractJSON.encode(self)
    }

    static func decodeAndValidate(
        _ data: Data
    ) throws -> AssignmentReplayEvidenceArtifact {
        let artifact = try ContractJSON.decode(
            AssignmentReplayEvidenceArtifact.self,
            from: data
        )
        let canonical = try artifact.validatedData()
        guard canonical == data else {
            throw ProductionAssignmentReplayEvidenceError.nonCanonicalEncoding
        }
        return artifact
    }
}

enum ProductionAssignmentReplayEvidenceError: Error, Equatable {
    case digestMismatch
    case nonCanonicalEncoding
    case invalidSchemaVersion
    case invalidCheckpoint
    case invalidSource
    case invalidAnswer
    case invalidController
    case invalidAssignment
    case invalidNextPrompt
    case invalidRevisions
    case configurationMismatch
}

enum ProductionAssignmentReplayCanonicalJSON {
    static func digest(_ value: some Encodable) throws -> String {
        try LocaleCatalogLoader.sha256Hex(ContractJSON.encode(value))
    }

    static func promptDigest(_ value: JSONValue) throws -> String {
        try LocaleCatalogLoader.sha256Hex(LosslessJSONSerializer.serialize(value))
    }
}
