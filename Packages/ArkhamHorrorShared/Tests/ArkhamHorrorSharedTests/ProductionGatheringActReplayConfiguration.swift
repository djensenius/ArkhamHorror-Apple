@testable import ArkhamHorrorShared
import Foundation

// swiftlint:disable:next type_name
enum ProductionGatheringActReplayConfigurationError: Error, Equatable {
    case invalidDeadline
    case invalidAuthToken
    case appleRevisionMismatch
    case contractRevisionMismatch
    case catalogRevisionMismatch
    case serverAttestationMismatch
    case checkpointPromptMismatch
}

// swiftlint:disable:next type_name
struct ProductionGatheringActReplayPromptIdentity: Equatable, Sendable {
    let gameID: GameID
    let ownerID: PlayerID
    let investigatorID: InvestigatorID
}

// swiftlint:disable:next type_name
private struct GatheringActReplayConfigurationValidation {
    let deadline: AssignmentReplayCoordinatorDeadline
    let serverProfile: ServerProfile
    let authToken: String
    let promptIdentity: ProductionGatheringActReplayPromptIdentity
    let expectedAppleRevision: String
    let expectedContractRevision: ContractRevision
    let expectedCatalogRevision: String
    let attestation: ProductionAssignmentReplayAttestation
}

// swiftlint:disable:next type_name
struct ProductionGatheringActReplayConfiguration: Sendable {
    static let startingQuestionVersion = 34
    static let confirmationQuestionVersion = 35
    static let resultingQuestionVersion = 36
    static let advancingActID = "c01108"
    static let advancedActID = "c01109"
    static let studyCardCode = "c01111"
    static let hallwayCardCode = "c01112"

    let deadline: AssignmentReplayCoordinatorDeadline
    let serverProfile: ServerProfile
    let authToken: String
    let promptIdentity: ProductionGatheringActReplayPromptIdentity
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

    init(
        deadline: AssignmentReplayCoordinatorDeadline,
        serverProfile: ServerProfile,
        authToken: String,
        promptIdentity: ProductionGatheringActReplayPromptIdentity,
        expectedAppleRevision: String,
        expectedContractRevision: ContractRevision,
        expectedCatalogRevision: String,
        attestation: ProductionAssignmentReplayAttestation
    ) throws {
        try Self.validate(
            GatheringActReplayConfigurationValidation(
                deadline: deadline,
                serverProfile: serverProfile,
                authToken: authToken,
                promptIdentity: promptIdentity,
                expectedAppleRevision: expectedAppleRevision,
                expectedContractRevision: expectedContractRevision,
                expectedCatalogRevision: expectedCatalogRevision,
                attestation: attestation
            )
        )
        self.deadline = deadline
        self.serverProfile = serverProfile
        self.authToken = authToken
        self.promptIdentity = promptIdentity
        self.expectedAppleRevision = expectedAppleRevision
        self.expectedContractRevision = expectedContractRevision
        self.expectedCatalogRevision = expectedCatalogRevision
        self.attestation = attestation
    }

    // swiftlint:disable:next function_body_length
    private static func validate(
        _ input: GatheringActReplayConfigurationValidation
    ) throws {
        let remainingSeconds: Double
        do {
            remainingSeconds = try input.deadline.remainingSeconds()
        } catch {
            throw ProductionGatheringActReplayConfigurationError
                .invalidDeadline
        }
        guard remainingSeconds.isFinite,
              remainingSeconds > 0,
              remainingSeconds <=
              ProductionAssignmentReplayConfiguration.maximumDeadlineSeconds
        else {
            throw ProductionGatheringActReplayConfigurationError
                .invalidDeadline
        }
        guard (1 ... 4096).contains(input.authToken.utf8.count),
              input.authToken.utf8.allSatisfy({
                  (0x21 ... 0x7E).contains($0)
              })
        else {
            throw ProductionGatheringActReplayConfigurationError
                .invalidAuthToken
        }
        guard ProductionAssignmentReplayConfiguration.isLowercaseHex(
            input.expectedAppleRevision,
            count: 40
        ) else {
            throw ProductionGatheringActReplayConfigurationError
                .appleRevisionMismatch
        }
        guard input.expectedContractRevision ==
            ContractPin.current.supportedSchemaRevision
        else {
            throw ProductionGatheringActReplayConfigurationError
                .contractRevisionMismatch
        }
        guard LocaleCatalogGrammar.isCatalogRevision(
            input.expectedCatalogRevision
        ) else {
            throw ProductionGatheringActReplayConfigurationError
                .catalogRevisionMismatch
        }

        let request = AssignmentReplayAttestationRequest(
            serverProfile: input.serverProfile,
            authToken: input.authToken,
            gameID: input.promptIdentity.gameID,
            playerID: input.promptIdentity.ownerID,
            investigatorID: input.promptIdentity.investigatorID,
            checkpointArtifactSHA256:
            input.attestation.checkpointValidation.artifactSHA256
        )
        do {
            try input.attestation.validate(request: request)
        } catch {
            throw ProductionGatheringActReplayConfigurationError
                .serverAttestationMismatch
        }
        let checkpoint = input.attestation.checkpointValidation
        guard checkpoint.contractRevision ==
            input.expectedContractRevision.description
        else {
            throw ProductionGatheringActReplayConfigurationError
                .contractRevisionMismatch
        }
        guard checkpoint.questionVersion == startingQuestionVersion,
              checkpoint.promptTag ==
              BasicChoiceQuestionKind.playerWindowChooseOne.rawValue
        else {
            throw ProductionGatheringActReplayConfigurationError
                .checkpointPromptMismatch
        }
    }
}
