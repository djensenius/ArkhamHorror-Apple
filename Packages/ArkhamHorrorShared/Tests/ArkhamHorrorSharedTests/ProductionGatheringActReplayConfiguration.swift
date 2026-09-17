@testable import ArkhamHorrorShared
import Foundation

private let gatheringAtticQ42PromptSHA256s = [
    "12:0:1:2":
        "28319921e5c12435567f794fdd6eb5ab3e6e89f63ba38f52e0b099b38ae1824a",
    "12:0:2:1":
        "1c0b5dd3b8e807516352e87b8378df4171302567b60f715cf28ad7f5f3330c6f",
    "12:1:0:2":
        "3027ec9916d4bb14542680ee71c53a19b6a7f9c9b167877459acbbb419adcafe",
    "12:2:0:1":
        "a169b0620713fffaa550f07d26664c0eaa626ca1c95ec9c29ae3c60adeea8d65",
    "12:1:2:0":
        "0f9cd56d4ce4d1d638d567bf7160ce140795d8f3afef99014fc2ad0afacdf8a8",
    "12:2:1:0":
        "8a5deae8ecebeae6e8d07fadc03ada5068d0dfde75b07c5817c10c40be7b57b6",
    "13:0:1:2":
        "5e57090f25063d7515ebeb58271ec71ead11bf8e6588b58ae9eeced2fe0cdf4b",
    "13:0:2:1":
        "a1a25cb87379b7620290e75d7cb963ac43c68236ec875a6718656b7724ffb739",
    "13:1:0:2":
        "90f341be4d8227bf096bcf15215f23202ff8fd6cf842ff7ee90a495d807ebd90",
    "13:2:0:1":
        "9233798958ec994090a86a6887ee59667e76b5fde7ecc4b82b5d822e55ee32a3",
    "13:1:2:0":
        "d45350e80f83ba2b89cfd16382891812d6850e658c8f1306c62b1b54f9375684",
    "13:2:1:0":
        "c2bd1c56f64249b4945b89770781d2136c26ab381291a4ad14328b713be4dec9",
]

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

    var locationCardCode: String {
        switch self {
        case .cellar:
            "c01114"
        case .attic:
            "c01113"
        }
    }

    func movementDescriptor(
        locationID: String
    ) -> QuestionPresentation.Choice {
        .gatheringMovement(
            sourceIndex: movementSourceIndex,
            cardCode: locationCardCode,
            locationID: locationID
        )
    }

    func forcedAbilityDescriptor(
        locationID: String
    ) -> QuestionPresentation.Choice {
        .gatheringForcedAbility(
            cardCode: locationCardCode,
            locationID: locationID
        )
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

    var q39PromptSHA256s: Set<String> {
        switch self {
        case .cellar:
            [
                q39PromptSHA256,
                "5329c8b70fc8e393ba73ea49556c7fa9f599af1cd15e85efab54f765b2f02166",
            ]
        case .attic:
            [
                q39PromptSHA256,
                "ca5d812821f318f2502eb6fd3dfe30a6baa811e0c19d9d03b504be45ac0707d5",
            ]
        }
    }

    var firstContinuationPromptSHA256: String {
        switch self {
        case .cellar:
            "1276b303023cd7aee7823721fb1dadeb5daaa6df86f5c36697894f0effeb5a85"
        case .attic:
            "99258cd532aec6632832e3766bcf3a4a40f3caaf186e7e23684bd944b4f51a95"
        }
    }

    var secondContinuationPromptSHA256: String {
        switch self {
        case .cellar:
            "a62508e1da45f79d7548903fbc6be47641c91bdcb85e320a50026abdda56eecb"
        case .attic:
            "f47283f0c5a1537cbee8cdcb7b2b5faef740a5fa44ec8a8341d92a64e10594f1"
        }
    }

    func resultingContinuationPromptSHA256(
        choiceCount: Int,
        atticMovementSourceIndex: Int? = nil,
        hallwayInvestigationSourceIndex: Int? = nil,
        cellarMovementSourceIndex: Int? = nil
    ) -> String? {
        switch self {
        case .cellar:
            guard choiceCount == 1,
                  atticMovementSourceIndex == nil,
                  hallwayInvestigationSourceIndex == nil,
                  cellarMovementSourceIndex == nil
            else { return nil }
            return
                "99258cd532aec6632832e3766bcf3a4a40f3caaf186e7e23684bd944b4f51a95"
        case .attic:
            guard let atticMovementSourceIndex,
                  let hallwayInvestigationSourceIndex,
                  let cellarMovementSourceIndex
            else { return nil }
            let firstRoleSourceIndex = choiceCount - 3
            let roleOffsets = [
                atticMovementSourceIndex - firstRoleSourceIndex,
                hallwayInvestigationSourceIndex - firstRoleSourceIndex,
                cellarMovementSourceIndex - firstRoleSourceIndex,
            ]
            let key = ([choiceCount] + roleOffsets)
                .map(String.init)
                .joined(separator: ":")
            return gatheringAtticQ42PromptSHA256s[key]
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

struct GatheringMovementEntryDestination: Equatable, Sendable {
    let branch: GatheringMovementEntryBranch
    let locationID: LocationID
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
    static let firstContinuationQuestionVersion = 40
    static let secondContinuationQuestionVersion = 41
    static let resultingContinuationQuestionVersion = 42
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
