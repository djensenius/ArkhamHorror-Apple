@testable import ArkhamHorrorShared
import Foundation

enum ProductionAssignmentReplayCheckpoint: String, CaseIterable, ProductionReplayCheckpoint {
    case damageFirstThenRemainingHorror = "damage-first-then-remaining-horror"
    case horrorFirstThenRemainingDamage = "horror-first-then-remaining-damage"

    var sourceIndex: Int {
        switch self {
        case .damageFirstThenRemainingHorror: 0
        case .horrorFirstThenRemainingDamage: 1
        }
    }

    var selectedAssignmentKind: EnemyAttackAssignmentKind {
        switch self {
        case .damageFirstThenRemainingHorror: .damage
        case .horrorFirstThenRemainingDamage: .horror
        }
    }

    var nextAssignmentKind: EnemyAttackAssignmentKind {
        switch self {
        case .damageFirstThenRemainingHorror: .horror
        case .horrorFirstThenRemainingDamage: .damage
        }
    }

    var assignmentBefore: AssignmentReplayFields {
        AssignmentReplayFields(
            assignedHealthDamage: 0,
            assignedSanityDamage: 0
        )
    }

    var assignmentAfter: AssignmentReplayFields {
        switch self {
        case .damageFirstThenRemainingHorror:
            AssignmentReplayFields(
                assignedHealthDamage: 1,
                assignedSanityDamage: 0
            )
        case .horrorFirstThenRemainingDamage:
            AssignmentReplayFields(
                assignedHealthDamage: 0,
                assignedSanityDamage: 1
            )
        }
    }

    var assignmentDelta: AssignmentReplayFields {
        assignmentAfter.subtracting(assignmentBefore)
    }
}

extension EnemyAttackAssignmentKind {
    var productionReplayName: String {
        switch self {
        case .damage: "damage"
        case .horror: "horror"
        }
    }
}

struct AssignmentReplayFields: Codable, Equatable, Sendable {
    let assignedHealthDamage: Int
    let assignedSanityDamage: Int

    func subtracting(
        _ other: AssignmentReplayFields
    ) -> AssignmentReplayFields {
        AssignmentReplayFields(
            assignedHealthDamage: assignedHealthDamage - other.assignedHealthDamage,
            assignedSanityDamage: assignedSanityDamage - other.assignedSanityDamage
        )
    }
}

struct ProductionAssignmentReplayPromptIdentity: Equatable, Sendable {
    let gameID: GameID
    let ownerID: PlayerID
    let enemyID: EnemyID
    let investigatorID: InvestigatorID
}

enum AssignmentReplayConfigurationError: Error, Equatable {
    case invalidDeadline
    case invalidAuthToken
    case appleRevisionMismatch
    case contractRevisionMismatch
    case catalogRevisionMismatch
    case serverAttestationMismatch
}

private struct ReplayConfigurationValidation {
    let deadlineSeconds: Double
    let serverProfile: ServerProfile
    let authToken: String
    let promptIdentity: ProductionAssignmentReplayPromptIdentity
    let expectedAppleRevision: String
    let expectedContractRevision: ContractRevision
    let expectedCatalogRevision: String
    let attestation: ProductionAssignmentReplayAttestation
}

struct ProductionAssignmentReplayConfiguration: Sendable {
    static let maximumDeadlineSeconds = 300.0

    let checkpoint: ProductionAssignmentReplayCheckpoint
    let deadlineSeconds: Double
    let serverProfile: ServerProfile
    let authToken: String
    let promptIdentity: ProductionAssignmentReplayPromptIdentity
    let expectedAppleRevision: String
    let expectedContractRevision: ContractRevision
    let expectedCatalogRevision: String
    let attestation: ProductionAssignmentReplayAttestation

    var validatedCheckpoint: AssignmentReplayValidatedCheckpoint {
        attestation.checkpointValidation
    }

    var expectedPromptDigest: String {
        validatedCheckpoint.promptSHA256
    }

    var expectedPromptVersion: Int {
        validatedCheckpoint.questionVersion
    }

    init(
        checkpoint: ProductionAssignmentReplayCheckpoint,
        deadlineSeconds: Double,
        serverProfile: ServerProfile,
        authToken: String,
        promptIdentity: ProductionAssignmentReplayPromptIdentity,
        expectedAppleRevision: String,
        expectedContractRevision: ContractRevision,
        expectedCatalogRevision: String,
        attestation: ProductionAssignmentReplayAttestation
    ) throws {
        try Self.validate(
            ReplayConfigurationValidation(
                deadlineSeconds: deadlineSeconds,
                serverProfile: serverProfile,
                authToken: authToken,
                promptIdentity: promptIdentity,
                expectedAppleRevision: expectedAppleRevision,
                expectedContractRevision: expectedContractRevision,
                expectedCatalogRevision: expectedCatalogRevision,
                attestation: attestation
            )
        )

        self.checkpoint = checkpoint
        self.deadlineSeconds = deadlineSeconds
        self.serverProfile = serverProfile
        self.authToken = authToken
        self.promptIdentity = promptIdentity
        self.expectedAppleRevision = expectedAppleRevision
        self.expectedContractRevision = expectedContractRevision
        self.expectedCatalogRevision = expectedCatalogRevision
        self.attestation = attestation
    }

    private static func validate(
        _ input: ReplayConfigurationValidation
    ) throws {
        guard input.deadlineSeconds.isFinite,
              input.deadlineSeconds > 0,
              input.deadlineSeconds <= maximumDeadlineSeconds
        else {
            throw AssignmentReplayConfigurationError.invalidDeadline
        }
        guard (1 ... 4096).contains(input.authToken.utf8.count),
              input.authToken.utf8.allSatisfy({
                  (0x21 ... 0x7E).contains($0)
              })
        else {
            throw AssignmentReplayConfigurationError.invalidAuthToken
        }
        guard isLowercaseHex(input.expectedAppleRevision, count: 40) else {
            throw AssignmentReplayConfigurationError.appleRevisionMismatch
        }
        guard input.expectedContractRevision ==
            ContractPin.current.supportedSchemaRevision
        else {
            throw AssignmentReplayConfigurationError.contractRevisionMismatch
        }
        guard LocaleCatalogGrammar.isCatalogRevision(
            input.expectedCatalogRevision
        )
        else {
            throw AssignmentReplayConfigurationError.catalogRevisionMismatch
        }
        let attestationRequest = AssignmentReplayAttestationRequest(
            serverProfile: input.serverProfile,
            authToken: input.authToken,
            gameID: input.promptIdentity.gameID,
            playerID: input.promptIdentity.ownerID,
            investigatorID: input.promptIdentity.investigatorID,
            checkpointArtifactSHA256:
            input.attestation.checkpointValidation.artifactSHA256
        )
        do {
            try input.attestation.validate(request: attestationRequest)
        } catch {
            throw AssignmentReplayConfigurationError.serverAttestationMismatch
        }
        guard input.attestation.checkpointValidation.contractRevision ==
            input.expectedContractRevision.description
        else {
            throw AssignmentReplayConfigurationError.contractRevisionMismatch
        }
    }

    var attestationRequest: AssignmentReplayAttestationRequest {
        AssignmentReplayAttestationRequest(
            serverProfile: serverProfile,
            authToken: authToken,
            gameID: promptIdentity.gameID,
            playerID: promptIdentity.ownerID,
            investigatorID: promptIdentity.investigatorID,
            checkpointArtifactSHA256:
            attestation.checkpointValidation.artifactSHA256
        )
    }

    static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count
            && value.utf8.allSatisfy {
                (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
            }
    }
}
