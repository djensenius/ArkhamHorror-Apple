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

enum GatheringMovementEntryBranch: String, Codable, Equatable, Sendable {
    case cellar
    case attic

    var movementSourceIndex: Int {
        switch self {
        case .cellar:
            9
        case .attic:
            10
        }
    }

    var locationID: String {
        switch self {
        case .cellar:
            QuestionPresentation.Choice.gatheringCellarLocationID
        case .attic:
            QuestionPresentation.Choice.gatheringAtticLocationID
        }
    }

    var locationCardCode: String {
        switch self {
        case .cellar:
            "c01114"
        case .attic:
            "c01113"
        }
    }

    var movementDescriptor: QuestionPresentation.Choice {
        switch self {
        case .cellar:
            .gatheringCellarMove
        case .attic:
            .gatheringAtticMove
        }
    }

    var forcedAbilityDescriptor: QuestionPresentation.Choice {
        switch self {
        case .cellar:
            .gatheringCellarForcedAbility
        case .attic:
            .gatheringAtticForcedAbility
        }
    }

    var assignmentDescriptor: QuestionPresentation.Choice {
        switch self {
        case .cellar:
            .gatheringCellarDamageAssignment
        case .attic:
            .gatheringAtticHorrorAssignment
        }
    }

    var q37PromptSHA256: String {
        switch self {
        case .cellar:
            "81226881d2744c27b99dc9e0169dc6da66b50616628d0cfe770fd42411adab7f"
        case .attic:
            "e2bdcb51bb439cf4e0e4b3e143658ef8bdc56607369e4a4a0e9a6209863e0fef"
        }
    }

    var q38PromptSHA256: String {
        switch self {
        case .cellar:
            "8259de19c744c3b781b434e40b4a78cd5d8a8af0a324aec8c16f009111f9ed2b"
        case .attic:
            "63ef3583c5440bb0eea5cc0c8f05bcf21d633ec5e9508d2f3bd45572a7abb43d"
        }
    }

    var q39PromptSHA256: String {
        switch self {
        case .cellar:
            "e8266d1d38bf743b8ae3015c853c6472face1be3b18c5b7fbdc4452d8f82beaf"
        case .attic:
            "6aa58eed631203e4025fa22f397382042bcdb2159ca7613319f125928c1bda92"
        }
    }

    var resultingDamage: Int {
        switch self {
        case .cellar:
            2
        case .attic:
            1
        }
    }

    var resultingHorror: Int {
        switch self {
        case .cellar:
            3
        case .attic:
            4
        }
    }
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
    static let forcedAbilityQuestionVersion = 37
    static let assignmentQuestionVersion = 38
    static let postEntryQuestionVersion = 39
    static let advancingActID = "c01108"
    static let advancedActID = "c01109"
    static let studyCardCode = "c01111"
    static let hallwayCardCode = "c01112"
    static let movementPromptSHA256 =
        "ccc03aba15081592b2163fac1b61e433b20333486b650e1ed359ac598d2262f8"

    let deadline: AssignmentReplayCoordinatorDeadline
    let serverProfile: ServerProfile
    let authToken: String
    let promptIdentity: ProductionGatheringActReplayPromptIdentity
    let expectedAppleRevision: String
    let expectedContractRevision: ContractRevision
    let expectedCatalogRevision: String
    let attestation: ProductionAssignmentReplayAttestation
    let movementEntryBranch: GatheringMovementEntryBranch?

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
        attestation: ProductionAssignmentReplayAttestation,
        movementEntryBranch: GatheringMovementEntryBranch?
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
        self.movementEntryBranch = movementEntryBranch
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
