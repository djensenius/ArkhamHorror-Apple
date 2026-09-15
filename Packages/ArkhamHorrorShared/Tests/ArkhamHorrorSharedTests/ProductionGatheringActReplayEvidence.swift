@testable import ArkhamHorrorShared
import Foundation

// swiftlint:disable file_length

struct GatheringActReplayAnswerEvidence: Codable, Equatable, Sendable {
    let answer: BasicChoiceAnswer
    let canonicalSHA256: String
    let canonicalUTF8: String

    init(answer: BasicChoiceAnswer) throws {
        let data = try ContractJSON.encode(answer)
        guard let canonicalUTF8 = String(data: data, encoding: .utf8) else {
            throw ProductionGatheringActReplayEvidenceError.invalidAnswer
        }
        self.answer = answer
        canonicalSHA256 = LocaleCatalogLoader.sha256Hex(data)
        self.canonicalUTF8 = canonicalUTF8
    }

    func validate(
        choice: Int,
        playerID: PlayerID,
        questionVersion: Int
    ) throws {
        let expected = BasicChoiceAnswer(
            choice: choice,
            playerID: playerID,
            questionVersion: questionVersion
        )
        let data = Data(canonicalUTF8.utf8)
        guard answer == expected,
              try ContractJSON.decode(
                  BasicChoiceAnswer.self,
                  from: data
              ) == answer,
              try ContractJSON.encode(answer) == data,
              canonicalSHA256 == LocaleCatalogLoader.sha256Hex(data)
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidAnswer
        }
    }
}

struct GatheringActReplayDescriptorEvidence: Codable, Equatable, Sendable {
    let sourceIndex: Int
    let kind: String
    let actorID: String?
    let entityKind: String?
    let entityID: String?
    let abilityCardCode: String?
    let abilityIndex: Int?
    let abilityType: String?
    let abilityActions: [String]?
    let abilityCanBeCancelled: Bool?
    let costKind: String?
    let costAmountKind: String?
    let costAmountValue: Int?
    let costScope: String?

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    init(choice: QuestionPresentation.Choice) {
        sourceIndex = choice.sourceIndex
        kind = choice.kind.rawValue
        actorID = choice.actorID
        entityKind = choice.entity?.kind.rawValue
        entityID = choice.entity?.id
        abilityCardCode = choice.ability?.cardCode
        abilityIndex = choice.ability?.index
        abilityType = choice.ability?.type.rawValue
        abilityActions = choice.ability?.actions.map(\.rawValue)
        abilityCanBeCancelled = choice.ability?.canBeCancelled

        switch choice.cost {
        case let .groupClue(amount, scope):
            costKind = "groupClue"
            switch amount {
            case let .perPlayer(value):
                costAmountKind = "perPlayer"
                costAmountValue = value
            case let .fixed(value):
                costAmountKind = "fixed"
                costAmountValue = value
            case .fixedPlusPerPlayer:
                costAmountKind = "fixedPlusPerPlayer"
                costAmountValue = nil
            case .byPlayerCount:
                costAmountKind = "byPlayerCount"
                costAmountValue = nil
            case .variable:
                costAmountKind = "variable"
                costAmountValue = nil
            case .star:
                costAmountKind = "star"
                costAmountValue = nil
            case .unknown:
                costAmountKind = "unknown"
                costAmountValue = nil
            }
            switch scope {
            case .anywhere:
                costScope = "anywhere"
            case .sameLocation:
                costScope = "sameLocation"
            case let .location(locationID):
                costScope = "location:\(locationID)"
            case .other:
                costScope = "other"
            }
        case .none:
            costKind = nil
            costAmountKind = nil
            costAmountValue = nil
            costScope = nil
        default:
            costKind = "other"
            costAmountKind = nil
            costAmountValue = nil
            costScope = nil
        }
    }
}

struct GatheringActReplayPromptEvidence: Codable, Equatable, Sendable {
    let version: Int
    let rawTag: String
    let questionKind: String
    let choiceCount: Int
    let sourceIndices: [Int]
    let actionableSourceIndices: [Int]
    let canonicalSHA256: String
    let selectedDescriptor: GatheringActReplayDescriptorEvidence?

    @MainActor
    init(
        prompt: BasicChoicePromptPresentation,
        projection: BoardProjection,
        selectedSourceIndex: Int?
    ) throws {
        guard let semantic = prompt.semanticPresentation,
              case let .object(rawQuestion) = prompt.identity.rawQuestion,
              case let .string(rawTag)? = rawQuestion["tag"]
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidPrompt
        }
        let choices = prompt.choices
        version = prompt.questionVersion
        self.rawTag = rawTag
        questionKind = semantic.presentation.questionKind.rawValue
        choiceCount = semantic.presentation.choiceCount
        sourceIndices = choices.map(\.index)
        actionableSourceIndices = choices.compactMap {
            prompt.isChoiceActionable($0, in: projection) ? $0.index : nil
        }
        canonicalSHA256 =
            try ProductionAssignmentReplayCanonicalJSON.promptDigest(
                prompt.identity.rawQuestion
            )
        if let selectedSourceIndex {
            guard let descriptor = semantic.descriptor(
                forSourceIndex: selectedSourceIndex
            ) else {
                throw ProductionGatheringActReplayEvidenceError.invalidPrompt
            }
            selectedDescriptor = GatheringActReplayDescriptorEvidence(
                choice: descriptor
            )
        } else {
            selectedDescriptor = nil
        }
    }
}

struct GatheringActReplayControllerEvidence: Codable, Equatable, Sendable {
    let jumpHandled: Bool
    let focusAfterJump: String
    let moveCount: Int
    let allMovesHandled: Bool
    let focusSourceIndices: [Int]
    let focusBeforePrimaryAction: String
    let primaryActionHandled: Bool
    let selectedSourceIndex: Int
    let submissionResult: String

    func validate(
        selectedSourceIndex expectedSourceIndex: Int,
        expectedFocusSourceIndices: [Int]
    ) throws {
        guard jumpHandled,
              focusAfterJump == BoardFocusID.promptChoice(0).rawValue,
              !expectedFocusSourceIndices.isEmpty,
              expectedFocusSourceIndices.first == 0,
              expectedFocusSourceIndices.last == expectedSourceIndex,
              focusSourceIndices == expectedFocusSourceIndices,
              moveCount == focusSourceIndices.count - 1,
              allMovesHandled,
              focusBeforePrimaryAction ==
              BoardFocusID.promptChoice(expectedSourceIndex).rawValue,
              primaryActionHandled,
              selectedSourceIndex == expectedSourceIndex,
              ["retryableFailure", "sentAwaitingSnapshot"]
              .contains(submissionResult)
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidController
        }
    }
}

struct GatheringActReplayLocationEvidence: Codable, Equatable, Sendable {
    let id: LocationID
    let cardCode: String
    let revealed: Bool
    let investigatorIDs: [InvestigatorID]
    let enemyIDs: [EnemyID]
}

// swiftlint:disable opening_brace
private struct GatheringActReplayBoardStatePayload:
    Codable,
    Equatable,
    Sendable
{
    // swiftlint:enable opening_brace
    let source: AssignmentReplayObservationSource
    let gameID: GameID
    let gameRevision: String
    let playerID: PlayerID?
    let scenarioSteps: Int
    let actIDs: [String]
    let locations: [GatheringActReplayLocationEvidence]
    let investigatorID: InvestigatorID
    let investigatorLocationID: LocationID?
    let enemyIDs: [EnemyID]
}

// swiftlint:disable opening_brace
struct GatheringActReplayBoardStateEvidence:
    Codable,
    Equatable,
    Sendable
{
    // swiftlint:enable opening_brace
    let source: AssignmentReplayObservationSource
    let gameID: GameID
    let gameRevision: String
    let playerID: PlayerID?
    let scenarioSteps: Int
    let actIDs: [String]
    let locations: [GatheringActReplayLocationEvidence]
    let investigatorID: InvestigatorID
    let investigatorLocationID: LocationID?
    let enemyIDs: [EnemyID]
    let summaryCanonicalSHA256: String

    init(
        observation: AssignmentReplayAuthoritativeObservation,
        investigatorID: InvestigatorID
    ) throws {
        let snapshot = observation.snapshot
        let locations = snapshot.locations.compactMap(
            Self.locationEvidence
        ).sorted {
            $0.id.codingKey.stringValue < $1.id.codingKey.stringValue
        }
        guard let investigator = observation.projection.investigators
            .first(where: { $0.id == investigatorID })
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidState
        }
        let payload = GatheringActReplayBoardStatePayload(
            source: observation.source,
            gameID: observation.gameID,
            gameRevision: observation.gameRevision,
            playerID: observation.playerID,
            scenarioSteps: observation.projection.counters.scenarioSteps,
            actIDs: snapshot.acts.keys.map(\.codingKey.stringValue).sorted(),
            locations: locations,
            investigatorID: investigatorID,
            investigatorLocationID: investigator.currentLocationID,
            enemyIDs: snapshot.enemies.keys.sorted {
                $0.codingKey.stringValue < $1.codingKey.stringValue
            }
        )
        source = payload.source
        gameID = payload.gameID
        gameRevision = payload.gameRevision
        playerID = payload.playerID
        scenarioSteps = payload.scenarioSteps
        actIDs = payload.actIDs
        self.locations = payload.locations
        self.investigatorID = payload.investigatorID
        investigatorLocationID = payload.investigatorLocationID
        enemyIDs = payload.enemyIDs
        summaryCanonicalSHA256 =
            try ProductionAssignmentReplayCanonicalJSON.digest(payload)
    }

    func validateDigest() throws {
        let payload = GatheringActReplayBoardStatePayload(
            source: source,
            gameID: gameID,
            gameRevision: gameRevision,
            playerID: playerID,
            scenarioSteps: scenarioSteps,
            actIDs: actIDs,
            locations: locations,
            investigatorID: investigatorID,
            investigatorLocationID: investigatorLocationID,
            enemyIDs: enemyIDs
        )
        guard try summaryCanonicalSHA256 ==
            (ProductionAssignmentReplayCanonicalJSON.digest(payload))
        else {
            throw ProductionGatheringActReplayEvidenceError.digestMismatch
        }
    }

    private static func locationEvidence(
        _ entry: (key: LocationID, value: Location)
    ) -> GatheringActReplayLocationEvidence? {
        guard case let .ordinary(location) = entry.value else {
            return nil
        }
        return GatheringActReplayLocationEvidence(
            id: entry.key,
            cardCode: location.cardCode.rawValue,
            revealed: location.revealed,
            investigatorIDs: location.investigators.sorted {
                $0.codingKey.stringValue < $1.codingKey.stringValue
            },
            enemyIDs: location.enemies.sorted {
                $0.codingKey.stringValue < $1.codingKey.stringValue
            }
        )
    }
}

// swiftlint:disable opening_brace
// swiftlint:disable:next type_body_length
struct ProductionGatheringActReplayEvidence:
    Codable,
    Equatable,
    Sendable
{
    // swiftlint:enable opening_brace
    static let currentSchemaVersion = "1.0.0"

    let schemaVersion: String
    let attestation: ProductionAssignmentReplayAttestation
    let gameID: GameID
    let playerID: PlayerID
    let investigatorID: InvestigatorID
    let q34Prompt: GatheringActReplayPromptEvidence
    let q34Answer: GatheringActReplayAnswerEvidence
    let q34Controller: GatheringActReplayControllerEvidence
    let q34State: GatheringActReplayBoardStateEvidence
    let q35Prompt: GatheringActReplayPromptEvidence
    let q35Answer: GatheringActReplayAnswerEvidence
    let q35Controller: GatheringActReplayControllerEvidence
    let q36Prompt: GatheringActReplayPromptEvidence
    let q36State: GatheringActReplayBoardStateEvidence
    let revisions: AssignmentReplayRevisionEvidence

    func validateSemantics() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProductionGatheringActReplayEvidenceError
                .invalidSchemaVersion
        }
        try validateAttestation()
        try validateQ34()
        try validateQ35()
        try validateQ36()
        try validateBoardTransition()
        try validateRevisions()
    }

    func validate(
        configuration: ProductionGatheringActReplayConfiguration,
        attestation expectedAttestation: ProductionAssignmentReplayAttestation
    ) throws {
        try validateSemantics()
        guard attestation == expectedAttestation,
              attestation == configuration.attestation,
              gameID == configuration.promptIdentity.gameID,
              playerID == configuration.promptIdentity.ownerID,
              investigatorID ==
              configuration.promptIdentity.investigatorID,
              q34Prompt.canonicalSHA256 ==
              configuration.expectedPromptDigest,
              revisions.apple == configuration.expectedAppleRevision,
              revisions.contract ==
              configuration.expectedContractRevision,
              revisions.catalog ==
              configuration.expectedCatalogRevision
        else {
            throw ProductionGatheringActReplayEvidenceError
                .configurationMismatch
        }
    }

    // swiftlint:disable:next function_body_length
    private func validateAttestation() throws {
        try attestation.runningServerBuild.validate()
        try attestation.validatedCheckpoint.validate()
        let receipt = attestation.importReceipt
        try receipt.playerRemappings.forEach { try $0.validate() }
        guard receipt.playerRemappings.count == 1 else {
            throw ProductionGatheringActReplayEvidenceError
                .invalidAttestation
        }
        let remapping = receipt.playerRemappings[0]
        guard attestation.schemaVersion ==
            ProductionAssignmentReplayAttestation.schemaVersion,
            attestation.gameID == gameID,
            attestation.gameGitRevision == revisions.game,
            ProductionAssignmentReplayConfiguration.isLowercaseHex(
                attestation.gameGitRevision,
                count: 40
            ),
            ProductionAssignmentReplayConfiguration.isLowercaseHex(
                attestation.checkpointSHA256,
                count: 64
            ),
            ProductionAssignmentReplayConfiguration.isLowercaseHex(
                attestation.canonicalEnvelopeSHA256,
                count: 64
            ),
            attestation.validatedCheckpoint.prompt.questionVersion ==
            ProductionGatheringActReplayConfiguration
            .startingQuestionVersion,
            attestation.validatedCheckpoint.prompt.promptTag ==
            BasicChoiceQuestionKind.playerWindowChooseOne.rawValue,
            attestation.validatedCheckpoint.prompt.promptSHA256 ==
            q34Prompt.canonicalSHA256,
            receipt.gameID == attestation.gameID,
            receipt.gameGitRevision == attestation.gameGitRevision,
            receipt.backendBuild == attestation.runningServerBuild,
            receipt.checkpointSHA256 == attestation.checkpointSHA256,
            receipt.canonicalEnvelopeSHA256 ==
            attestation.canonicalEnvelopeSHA256,
            receipt.validatedCheckpoint ==
            attestation.validatedCheckpoint,
            try receipt.receiptSHA256 == (receipt.computedSHA256()),
            remapping.investigatorID == investigatorID,
            remapping.checkpointPlayerID ==
            attestation.validatedCheckpoint.prompt.playerID,
            remapping.importedPlayerID == playerID,
            remapping.livePlayerID == playerID,
            remapping.stateRemapped
        else {
            throw ProductionGatheringActReplayEvidenceError
                .invalidAttestation
        }
    }

    // swiftlint:disable:next function_body_length
    private func validateQ34() throws {
        let descriptor = q34Prompt.selectedDescriptor
        guard q34Prompt.version ==
            ProductionGatheringActReplayConfiguration
            .startingQuestionVersion,
            q34Prompt.rawTag ==
            BasicChoiceQuestionKind.playerWindowChooseOne.rawValue,
            q34Prompt.questionKind ==
            QuestionPresentation.Kind.playerWindowChooseOne.rawValue,
            q34Prompt.choiceCount == 13,
            q34Prompt.sourceIndices == Array(0 ... 12),
            q34Prompt.actionableSourceIndices.first == 0,
            q34Prompt.actionableSourceIndices.last == 12,
            q34Prompt.actionableSourceIndices ==
            q34Prompt.actionableSourceIndices.sorted(),
            Set(q34Prompt.actionableSourceIndices).count ==
            q34Prompt.actionableSourceIndices.count,
            ProductionAssignmentReplayConfiguration.isLowercaseHex(
                q34Prompt.canonicalSHA256,
                count: 64
            ),
            descriptor?.sourceIndex == 12,
            descriptor?.kind ==
            QuestionPresentation.ChoiceKind.advanceAct.rawValue,
            descriptor?.actorID == investigatorID.codingKey.stringValue,
            descriptor?.entityKind ==
            QuestionPresentation.EntityKind.act.rawValue,
            descriptor?.entityID ==
            ProductionGatheringActReplayConfiguration.advancingActID,
            descriptor?.abilityCardCode ==
            ProductionGatheringActReplayConfiguration.advancingActID,
            descriptor?.abilityIndex == 999,
            descriptor?.abilityType ==
            QuestionPresentation.AbilityType.objective.rawValue,
            descriptor?.abilityActions == [],
            descriptor?.abilityCanBeCancelled == true,
            descriptor?.costKind == "groupClue",
            descriptor?.costAmountKind == "perPlayer",
            descriptor?.costAmountValue == 2,
            descriptor?.costScope == "anywhere"
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidQ34
        }
        try q34Answer.validate(
            choice: 12,
            playerID: playerID,
            questionVersion:
            ProductionGatheringActReplayConfiguration
                .startingQuestionVersion
        )
        try q34Controller.validate(
            selectedSourceIndex: 12,
            expectedFocusSourceIndices:
            q34Prompt.actionableSourceIndices
        )
    }

    private func validateQ35() throws {
        let descriptor = q35Prompt.selectedDescriptor
        guard q35Prompt.version ==
            ProductionGatheringActReplayConfiguration
            .confirmationQuestionVersion,
            q35Prompt.rawTag == BasicChoiceQuestionKind.chooseOne.rawValue,
            q35Prompt.questionKind ==
            QuestionPresentation.Kind.chooseOne.rawValue,
            q35Prompt.choiceCount == 1,
            q35Prompt.sourceIndices == [0],
            q35Prompt.actionableSourceIndices == [0],
            ProductionAssignmentReplayConfiguration.isLowercaseHex(
                q35Prompt.canonicalSHA256,
                count: 64
            ),
            descriptor?.sourceIndex == 0,
            descriptor?.kind ==
            QuestionPresentation.ChoiceKind.advanceAct.rawValue,
            descriptor?.actorID == nil,
            descriptor?.entityKind ==
            QuestionPresentation.EntityKind.act.rawValue,
            descriptor?.entityID ==
            ProductionGatheringActReplayConfiguration.advancingActID,
            descriptor?.abilityCardCode == nil,
            descriptor?.abilityIndex == nil,
            descriptor?.abilityType == nil,
            descriptor?.abilityActions == nil,
            descriptor?.abilityCanBeCancelled == nil,
            descriptor?.costKind == nil,
            descriptor?.costAmountKind == nil,
            descriptor?.costAmountValue == nil,
            descriptor?.costScope == nil
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidQ35
        }
        try q35Answer.validate(
            choice: 0,
            playerID: playerID,
            questionVersion:
            ProductionGatheringActReplayConfiguration
                .confirmationQuestionVersion
        )
        try q35Controller.validate(
            selectedSourceIndex: 0,
            expectedFocusSourceIndices: [0]
        )
    }

    private func validateQ36() throws {
        guard q36Prompt.version ==
            ProductionGatheringActReplayConfiguration
            .resultingQuestionVersion,
            q36Prompt.rawTag ==
            BasicChoiceQuestionKind.playerWindowChooseOne.rawValue,
            q36Prompt.questionKind ==
            QuestionPresentation.Kind.playerWindowChooseOne.rawValue,
            q36Prompt.choiceCount > 0,
            q36Prompt.sourceIndices ==
            Array(0 ..< q36Prompt.choiceCount),
            !q36Prompt.actionableSourceIndices.isEmpty,
            q36Prompt.selectedDescriptor == nil,
            ProductionAssignmentReplayConfiguration.isLowercaseHex(
                q36Prompt.canonicalSHA256,
                count: 64
            )
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidQ36
        }
    }

    // swiftlint:disable:next function_body_length
    private func validateBoardTransition() throws {
        try q34State.validateDigest()
        try q36State.validateDigest()
        let studyLocations = q34State.locations.filter {
            $0.cardCode ==
                ProductionGatheringActReplayConfiguration.studyCardCode
        }
        let hallwayLocations = q36State.locations.filter {
            $0.cardCode ==
                ProductionGatheringActReplayConfiguration.hallwayCardCode
        }
        guard studyLocations.count == 1,
              hallwayLocations.count == 1
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidState
        }
        let study = studyLocations[0]
        let hallway = hallwayLocations[0]
        guard q34State.source == .rest,
              q34State.gameID == gameID,
              q34State.gameRevision == revisions.game,
              q34State.playerID == playerID,
              q34State.scenarioSteps ==
              ProductionGatheringActReplayConfiguration
              .startingQuestionVersion,
              q34State.actIDs == [
                  ProductionGatheringActReplayConfiguration.advancingActID,
              ],
              q34State.investigatorID == investigatorID,
              q34State.investigatorLocationID == study.id,
              study.revealed,
              study.investigatorIDs == [investigatorID],
              !study.enemyIDs.isEmpty,
              study.enemyIDs == q34State.enemyIDs,
              q34State.locations.allSatisfy({
                  $0.cardCode !=
                      ProductionGatheringActReplayConfiguration.hallwayCardCode
              }),
              q36State.source == .socket,
              q36State.gameID == gameID,
              q36State.gameRevision == revisions.game,
              q36State.playerID == nil,
              q36State.scenarioSteps ==
              ProductionGatheringActReplayConfiguration
              .resultingQuestionVersion,
              q36State.actIDs == [
                  ProductionGatheringActReplayConfiguration.advancedActID,
              ],
              q36State.investigatorID == investigatorID,
              q36State.investigatorLocationID == hallway.id,
              hallway.id != study.id,
              hallway.revealed,
              hallway.investigatorIDs == [investigatorID],
              q36State.locations.allSatisfy({
                  $0.cardCode !=
                      ProductionGatheringActReplayConfiguration.studyCardCode
              }),
              q36State.enemyIDs.isEmpty,
              q34State.enemyIDs.allSatisfy({
                  !q36State.enemyIDs.contains($0)
              })
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidState
        }
    }

    private func validateRevisions() throws {
        try revisions.serverBuild.validate()
        guard revisions.serverBuild == attestation.runningServerBuild,
              revisions.game == attestation.gameGitRevision,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  revisions.game,
                  count: 40
              ),
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  revisions.apple,
                  count: 40
              ),
              revisions.contract ==
              ContractPin.current.supportedSchemaRevision,
              LocaleCatalogGrammar.isCatalogRevision(revisions.catalog)
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidRevisions
        }
    }
}

// swiftlint:disable opening_brace
struct GatheringActReplayEvidenceArtifact:
    Codable,
    Equatable,
    Sendable
{
    // swiftlint:enable opening_brace
    let evidence: ProductionGatheringActReplayEvidence
    let evidenceCanonicalSHA256: String

    init(evidence: ProductionGatheringActReplayEvidence) throws {
        try evidence.validateSemantics()
        self.evidence = evidence
        evidenceCanonicalSHA256 =
            try ProductionAssignmentReplayCanonicalJSON.digest(evidence)
    }

    func validatedData() throws -> Data {
        try evidence.validateSemantics()
        guard try evidenceCanonicalSHA256 ==
            (ProductionAssignmentReplayCanonicalJSON.digest(evidence))
        else {
            throw ProductionGatheringActReplayEvidenceError.digestMismatch
        }
        return try ContractJSON.encode(self)
    }

    static func decodeAndValidate(
        _ data: Data
    ) throws -> GatheringActReplayEvidenceArtifact {
        let artifact = try ContractJSON.decode(
            GatheringActReplayEvidenceArtifact.self,
            from: data
        )
        guard try artifact.validatedData() == data else {
            throw ProductionGatheringActReplayEvidenceError
                .nonCanonicalEncoding
        }
        return artifact
    }
}

// swiftlint:disable:next type_name
enum ProductionGatheringActReplayEvidenceError: Error, Equatable {
    case digestMismatch
    case nonCanonicalEncoding
    case invalidSchemaVersion
    case invalidAttestation
    case invalidAnswer
    case invalidPrompt
    case invalidController
    case invalidQ34
    case invalidQ35
    case invalidQ36
    case invalidState
    case invalidRevisions
    case configurationMismatch
}
