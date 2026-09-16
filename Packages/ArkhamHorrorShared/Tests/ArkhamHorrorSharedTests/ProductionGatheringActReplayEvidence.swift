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

struct GatheringPostEntryPromptValidation: Equatable, Sendable {
    let selectedSourceIndex: Int
    let hallwayID: LocationID
}

// swiftlint:disable:next type_body_length
struct GatheringActReplayPromptEvidence: Codable, Equatable, Sendable {
    let version: Int
    let rawTag: String
    let questionKind: String
    let choiceCount: Int
    let sourceIndices: [Int]
    let actionableSourceIndices: [Int]
    let canonicalSHA256: String
    let selectedDescriptor: GatheringActReplayDescriptorEvidence?
    let governedDescriptors: [GatheringActReplayDescriptorEvidence]?
    let governedSourceEntityKind: String?
    let governedSourceEntityID: String?
    let governedSourceCardCode: String?

    init(
        version: Int,
        rawTag: String,
        questionKind: String,
        choiceCount: Int,
        sourceIndices: [Int],
        actionableSourceIndices: [Int],
        canonicalSHA256: String,
        selectedDescriptor: GatheringActReplayDescriptorEvidence?,
        governedDescriptors: [GatheringActReplayDescriptorEvidence]? = nil,
        governedSourceEntityKind: String? = nil,
        governedSourceEntityID: String? = nil,
        governedSourceCardCode: String? = nil
    ) {
        self.version = version
        self.rawTag = rawTag
        self.questionKind = questionKind
        self.choiceCount = choiceCount
        self.sourceIndices = sourceIndices
        self.actionableSourceIndices = actionableSourceIndices
        self.canonicalSHA256 = canonicalSHA256
        self.selectedDescriptor = selectedDescriptor
        self.governedDescriptors = governedDescriptors
        self.governedSourceEntityKind = governedSourceEntityKind
        self.governedSourceEntityID = governedSourceEntityID
        self.governedSourceCardCode = governedSourceCardCode
    }

    @MainActor
    // swiftlint:disable:next function_body_length
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
        governedSourceEntityKind =
            semantic.governedSource?.entity.kind.rawValue
        governedSourceEntityID = semantic.governedSource?.entity.id
        governedSourceCardCode = semantic.governedSource?.cardCode
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
        switch version {
        case ProductionGatheringActReplayConfiguration
            .postEntryQuestionVersion:
            let descriptors = [9, 10].compactMap(
                semantic.descriptor(forSourceIndex:)
            ).map(GatheringActReplayDescriptorEvidence.init(choice:))
            guard descriptors.count == 2 else {
                throw ProductionGatheringActReplayEvidenceError.invalidPrompt
            }
            governedDescriptors = descriptors
        case ProductionGatheringActReplayConfiguration
            .resultingContinuationQuestionVersion:
            governedDescriptors = semantic.presentation.choices.map(
                GatheringActReplayDescriptorEvidence.init(choice:)
            )
        default:
            governedDescriptors = nil
        }
    }

    func validateResultingPrompt(
        selectedDescriptor expectedDescriptor:
        QuestionPresentation.Choice? = nil
    ) throws {
        let expectedSourceIndices = Array(0 ..< 12)
        guard version ==
            ProductionGatheringActReplayConfiguration
            .resultingQuestionVersion,
            rawTag ==
            BasicChoiceQuestionKind.playerWindowChooseOne.rawValue,
            questionKind ==
            QuestionPresentation.Kind.playerWindowChooseOne.rawValue,
            choiceCount == expectedSourceIndices.count,
            sourceIndices == expectedSourceIndices,
            actionableSourceIndices == expectedSourceIndices,
            selectedDescriptor == expectedDescriptor.map(
                GatheringActReplayDescriptorEvidence.init(choice:)
            ),
            governedDescriptors == nil,
            governedSourceEntityKind == nil,
            governedSourceEntityID == nil,
            governedSourceCardCode == nil,
            ProductionAssignmentReplayConfiguration.isLowercaseHex(
                canonicalSHA256,
                count: 64
            )
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidQ36
        }
    }

    func validateMovementPrompt(
        branch: GatheringMovementEntryBranch
    ) throws -> LocationID {
        guard let locationIDText = selectedDescriptor?.entityID,
              let locationID = LocationID(
                  codingKey: AnyCodingKey(stringValue: locationIDText)
              )
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidQ36
        }
        try validateResultingPrompt(
            selectedDescriptor: branch.movementDescriptor(
                locationID: locationIDText
            )
        )
        guard canonicalSHA256 ==
            ProductionGatheringActReplayConfiguration.movementPromptSHA256
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidQ36
        }
        return locationID
    }

    func validateForcedAbilityPrompt(
        destination: GatheringMovementEntryDestination
    ) throws {
        guard version ==
            ProductionGatheringActReplayConfiguration
            .forcedAbilityQuestionVersion,
            rawTag == BasicChoiceQuestionKind.windowChooseOne.rawValue,
            questionKind ==
            QuestionPresentation.Kind.windowChooseOne.rawValue,
            choiceCount == 1,
            sourceIndices == [0],
            actionableSourceIndices == [0],
            canonicalSHA256 == destination.branch.q37PromptSHA256,
            selectedDescriptor ==
            GatheringActReplayDescriptorEvidence(
                choice: destination.branch.forcedAbilityDescriptor(
                    locationID:
                    destination.locationID.codingKey.stringValue
                )
            ),
            governedDescriptors == nil,
            governedSourceEntityKind == nil,
            governedSourceEntityID == nil,
            governedSourceCardCode == nil
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidQ37
        }
    }

    func validateAssignmentPrompt(
        destination: GatheringMovementEntryDestination
    ) throws {
        guard version ==
            ProductionGatheringActReplayConfiguration
            .assignmentQuestionVersion,
            rawTag == "QuestionWithSource",
            questionKind == QuestionPresentation.Kind.chooseOne.rawValue,
            choiceCount == 1,
            sourceIndices == [0],
            actionableSourceIndices == [0],
            canonicalSHA256 == destination.branch.q38PromptSHA256,
            selectedDescriptor ==
            GatheringActReplayDescriptorEvidence(
                choice: destination.branch.assignmentDescriptor
            ),
            governedDescriptors == nil,
            governedSourceEntityKind ==
            QuestionPresentation.EntityKind.location.rawValue,
            governedSourceEntityID ==
            destination.locationID.codingKey.stringValue,
            governedSourceCardCode == destination.branch.locationCardCode
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidQ38
        }
    }

    // swiftlint:disable:next function_body_length
    func validatePostEntryPrompt(
        destination: GatheringMovementEntryDestination
    ) throws -> GatheringPostEntryPromptValidation {
        let sourceIndexSet = Set(sourceIndices)
        guard let descriptors = governedDescriptors,
              descriptors.count == 2,
              let investigation = descriptors.first(where: {
                  $0.kind ==
                      QuestionPresentation.ChoiceKind.investigate.rawValue
              }),
              let hallway = descriptors.first(where: {
                  $0.kind == QuestionPresentation.ChoiceKind.move.rawValue
                      && $0.abilityCardCode ==
                      ProductionGatheringActReplayConfiguration.hallwayCardCode
              }),
              let hallwayIDText = hallway.entityID,
              let hallwayID = LocationID(
                  codingKey: AnyCodingKey(stringValue: hallwayIDText)
              ),
              Set([
                  investigation.sourceIndex,
                  hallway.sourceIndex,
              ]) == [9, 10],
              LocationID(
                  codingKey: AnyCodingKey(stringValue: hallwayIDText)
              ) != nil
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidQ39
        }
        let expectedDescriptors = [
            GatheringActReplayDescriptorEvidence(
                choice: .gatheringInvestigation(
                    sourceIndex: investigation.sourceIndex,
                    cardCode: destination.branch.locationCardCode,
                    locationID: destination.locationID.codingKey.stringValue
                )
            ),
            GatheringActReplayDescriptorEvidence(
                choice: .gatheringHallwayMovement(
                    sourceIndex: hallway.sourceIndex,
                    locationID: hallwayIDText
                )
            ),
        ]
        let expectedSelectedDescriptor = switch destination.branch {
        case .cellar:
            expectedDescriptors[0]
        case .attic:
            expectedDescriptors[1]
        }
        guard version ==
            ProductionGatheringActReplayConfiguration.postEntryQuestionVersion,
            rawTag ==
            BasicChoiceQuestionKind.playerWindowChooseOne.rawValue,
            questionKind ==
            QuestionPresentation.Kind.playerWindowChooseOne.rawValue,
            choiceCount == 11,
            sourceIndices == Array(0 ..< 11),
            sourceIndexSet.count == 11,
            actionableSourceIndices == sourceIndices,
            destination.branch.q39PromptSHA256s.contains(canonicalSHA256),
            selectedDescriptor == expectedSelectedDescriptor,
            descriptors.sorted(by: { $0.sourceIndex < $1.sourceIndex }) ==
            expectedDescriptors.sorted(by: {
                $0.sourceIndex < $1.sourceIndex
            }),
            governedSourceEntityKind == nil,
            governedSourceEntityID == nil,
            governedSourceCardCode == nil
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidQ39
        }
        return GatheringPostEntryPromptValidation(
            selectedSourceIndex: expectedSelectedDescriptor.sourceIndex,
            hallwayID: hallwayID
        )
    }

    func validateFirstContinuationPrompt(
        branch: GatheringMovementEntryBranch,
        investigatorID: InvestigatorID
    ) throws {
        let expectedKind: QuestionPresentation.ChoiceKind = switch branch {
        case .cellar:
            .startSkillTest
        case .attic:
            .endTurn
        }
        let expectedQuestionKind: QuestionPresentation.Kind = switch branch {
        case .cellar:
            .chooseOne
        case .attic:
            .playerWindowChooseOne
        }
        let expectedRawTag: String = switch branch {
        case .cellar:
            BasicChoiceQuestionKind.chooseOne.rawValue
        case .attic:
            BasicChoiceQuestionKind.playerWindowChooseOne.rawValue
        }
        let expectedDescriptor = GatheringActReplayDescriptorEvidence(
            choice: QuestionPresentation.Choice(
                sourceIndex: 0,
                kind: expectedKind,
                actorID: investigatorID.codingKey.stringValue,
                entity: nil,
                label: nil,
                ability: nil,
                cost: nil
            )
        )
        guard version ==
            ProductionGatheringActReplayConfiguration
            .firstContinuationQuestionVersion,
            rawTag == expectedRawTag,
            questionKind == expectedQuestionKind.rawValue,
            choiceCount == 1,
            sourceIndices == [0],
            actionableSourceIndices == [0],
            selectedDescriptor == expectedDescriptor,
            governedDescriptors == nil,
            governedSourceEntityKind == nil,
            governedSourceEntityID == nil,
            governedSourceCardCode == nil,
            ProductionAssignmentReplayConfiguration.isLowercaseHex(
                canonicalSHA256,
                count: 64
            )
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidQ40
        }
    }

    func validateSecondContinuationPrompt(
        branch: GatheringMovementEntryBranch,
        investigatorID: InvestigatorID
    ) throws {
        let expectedChoice: QuestionPresentation.Choice = switch branch {
        case .cellar:
            QuestionPresentation.Choice(
                sourceIndex: 0,
                kind: .applySkillTestResults,
                actorID: nil,
                entity: nil,
                label: nil,
                ability: nil,
                cost: nil
            )
        case .attic:
            .encounterDeckDraw(
                actorID: investigatorID.codingKey.stringValue
            )
        }
        let expectedDescriptor = GatheringActReplayDescriptorEvidence(
            choice: expectedChoice
        )
        guard version ==
            ProductionGatheringActReplayConfiguration
            .secondContinuationQuestionVersion,
            rawTag == BasicChoiceQuestionKind.chooseOne.rawValue,
            questionKind == QuestionPresentation.Kind.chooseOne.rawValue,
            choiceCount == 1,
            sourceIndices == [0],
            actionableSourceIndices == [0],
            selectedDescriptor == expectedDescriptor,
            governedDescriptors == nil,
            governedSourceEntityKind == nil,
            governedSourceEntityID == nil,
            governedSourceCardCode == nil,
            ProductionAssignmentReplayConfiguration.isLowercaseHex(
                canonicalSHA256,
                count: 64
            )
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidQ41
        }
    }

    // swiftlint:disable:next function_body_length
    func validateResultingContinuationPrompt(
        branch: GatheringMovementEntryBranch,
        investigatorID: InvestigatorID
    ) throws {
        guard version ==
            ProductionGatheringActReplayConfiguration
            .resultingContinuationQuestionVersion,
            rawTag ==
            BasicChoiceQuestionKind.playerWindowChooseOne.rawValue,
            questionKind ==
            QuestionPresentation.Kind.playerWindowChooseOne.rawValue,
            selectedDescriptor == nil,
            governedSourceEntityKind == nil,
            governedSourceEntityID == nil,
            governedSourceCardCode == nil,
            ProductionAssignmentReplayConfiguration.isLowercaseHex(
                canonicalSHA256,
                count: 64
            )
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidQ42
        }

        let expectedEndTurn = GatheringActReplayDescriptorEvidence(
            choice: QuestionPresentation.Choice(
                sourceIndex: branch == .cellar ? 0 : 8,
                kind: .endTurn,
                actorID: investigatorID.codingKey.stringValue,
                entity: nil,
                label: nil,
                ability: nil,
                cost: nil
            )
        )
        switch branch {
        case .cellar:
            guard choiceCount == 1,
                  sourceIndices == [0],
                  actionableSourceIndices == [0],
                  governedDescriptors == [expectedEndTurn]
            else {
                throw ProductionGatheringActReplayEvidenceError.invalidQ42
            }
        case .attic:
            guard choiceCount == 12,
                  sourceIndices == Array(0 ..< 12),
                  actionableSourceIndices == sourceIndices,
                  let governedDescriptors,
                  governedDescriptors.map(\.sourceIndex) == sourceIndices,
                  governedDescriptors[0] ==
                  GatheringActReplayDescriptorEvidence(
                      choice: .gatheringGainResource
                  ),
                  governedDescriptors[1] ==
                  GatheringActReplayDescriptorEvidence(
                      choice: .gatheringDrawCard
                  ),
                  governedDescriptors[8] == expectedEndTurn,
                  (2 ... 7).allSatisfy({
                      guard let cardID = governedDescriptors[$0].entityID,
                            WireCardID(
                                codingKey:
                                AnyCodingKey(stringValue: cardID)
                            ) != nil
                      else { return false }
                      return governedDescriptors[$0] ==
                          GatheringActReplayDescriptorEvidence(
                              choice: .gatheringCardTarget(
                                  sourceIndex: $0,
                                  cardID: cardID
                              )
                          )
                  }),
                  let atticMovement = governedDescriptors.first(where: {
                      $0.kind ==
                          QuestionPresentation.ChoiceKind.move.rawValue
                          && $0.abilityCardCode == "c01113"
                  }),
                  let hallwayInvestigation =
                  governedDescriptors.first(where: {
                      $0.kind ==
                          QuestionPresentation.ChoiceKind
                          .investigate.rawValue
                          && $0.abilityCardCode ==
                          ProductionGatheringActReplayConfiguration
                          .hallwayCardCode
                  }),
                  let cellarMovement = governedDescriptors.first(where: {
                      $0.kind ==
                          QuestionPresentation.ChoiceKind.move.rawValue
                          && $0.abilityCardCode == "c01114"
                  }),
                  let atticID = atticMovement.entityID,
                  let hallwayID = hallwayInvestigation.entityID,
                  let cellarID = cellarMovement.entityID,
                  Set([
                      atticMovement.sourceIndex,
                      hallwayInvestigation.sourceIndex,
                      cellarMovement.sourceIndex,
                  ]) == [9, 10, 11],
                  atticMovement ==
                  GatheringActReplayDescriptorEvidence(
                      choice: .gatheringLocationMovement(
                          sourceIndex: atticMovement.sourceIndex,
                          cardCode: "c01113",
                          locationID: atticID,
                          cost: .action(1)
                      )
                  ),
                  hallwayInvestigation ==
                  GatheringActReplayDescriptorEvidence(
                      choice: .gatheringInvestigation(
                          sourceIndex:
                          hallwayInvestigation.sourceIndex,
                          cardCode:
                          ProductionGatheringActReplayConfiguration
                              .hallwayCardCode,
                          locationID: hallwayID
                      )
                  ),
                  cellarMovement ==
                  GatheringActReplayDescriptorEvidence(
                      choice: .gatheringMovement(
                          sourceIndex: cellarMovement.sourceIndex,
                          cardCode: "c01114",
                          locationID: cellarID
                      )
                  )
            else {
                throw ProductionGatheringActReplayEvidenceError.invalidQ42
            }
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
    let remainingActions: Int
    let damage: Int
    let horror: Int
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
    let remainingActions: Int
    let damage: Int
    let horror: Int
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
            remainingActions: investigator.remainingActions,
            damage: Self.tokenCount("Damage", in: investigator.tokenCounts),
            horror: Self.tokenCount("Horror", in: investigator.tokenCounts),
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
        remainingActions = payload.remainingActions
        damage = payload.damage
        horror = payload.horror
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
            remainingActions: remainingActions,
            damage: damage,
            horror: horror,
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

    private static func tokenCount(
        _ token: String,
        in counts: [BoardTokenSummary]
    ) -> Int {
        counts.first(where: { $0.token == token })?.count ?? 0
    }
}

struct GatheringReplayStateIdentity {
    let gameID: GameID
    let investigatorID: InvestigatorID
    let gameRevision: String
}

private struct GatheringContinuationStateExpectation {
    let version: Int
    let remainingActions: Int
    let locationID: LocationID
    let locationCardCode: String
}

struct GatheringMovementEntryValidationContext {
    let q36Prompt: GatheringActReplayPromptEvidence
    let q36State: GatheringActReplayBoardStateEvidence
    let gameID: GameID
    let playerID: PlayerID
    let investigatorID: InvestigatorID
    let gameRevision: String

    var stateIdentity: GatheringReplayStateIdentity {
        GatheringReplayStateIdentity(
            gameID: gameID,
            investigatorID: investigatorID,
            gameRevision: gameRevision
        )
    }
}

struct GatheringContinuationReplayEvidence: Codable, Equatable, Sendable {
    let q39Answer: GatheringActReplayAnswerEvidence
    let q39Controller: GatheringActReplayControllerEvidence
    let q40Prompt: GatheringActReplayPromptEvidence
    let q40Answer: GatheringActReplayAnswerEvidence
    let q40Controller: GatheringActReplayControllerEvidence
    let q40State: GatheringActReplayBoardStateEvidence
    let q41Prompt: GatheringActReplayPromptEvidence
    let q41Answer: GatheringActReplayAnswerEvidence
    let q41Controller: GatheringActReplayControllerEvidence
    let q41State: GatheringActReplayBoardStateEvidence
    let q42Prompt: GatheringActReplayPromptEvidence
    let q42State: GatheringActReplayBoardStateEvidence

    var submittedAnswers: [GatheringActReplayAnswerEvidence] {
        [q39Answer, q40Answer, q41Answer]
    }

    // swiftlint:disable:next function_body_length
    func validate(
        branch: GatheringMovementEntryBranch,
        destination: GatheringMovementEntryDestination,
        postEntry: GatheringPostEntryPromptValidation,
        identity: GatheringReplayStateIdentity,
        playerID: PlayerID
    ) throws {
        try q39Answer.validate(
            choice: postEntry.selectedSourceIndex,
            playerID: playerID,
            questionVersion:
            ProductionGatheringActReplayConfiguration
                .postEntryQuestionVersion
        )
        try q39Controller.validate(
            selectedSourceIndex: postEntry.selectedSourceIndex,
            expectedFocusSourceIndices:
            Array(0 ... postEntry.selectedSourceIndex)
        )
        try q40Prompt.validateFirstContinuationPrompt(
            branch: branch,
            investigatorID: identity.investigatorID
        )
        try q40Answer.validate(
            choice: 0,
            playerID: playerID,
            questionVersion:
            ProductionGatheringActReplayConfiguration
                .firstContinuationQuestionVersion
        )
        try q40Controller.validate(
            selectedSourceIndex: 0,
            expectedFocusSourceIndices: [0]
        )
        try q41Prompt.validateSecondContinuationPrompt(
            branch: branch,
            investigatorID: identity.investigatorID
        )
        try q41Answer.validate(
            choice: 0,
            playerID: playerID,
            questionVersion:
            ProductionGatheringActReplayConfiguration
                .secondContinuationQuestionVersion
        )
        try q41Controller.validate(
            selectedSourceIndex: 0,
            expectedFocusSourceIndices: [0]
        )
        try q42Prompt.validateResultingContinuationPrompt(
            branch: branch,
            investigatorID: identity.investigatorID
        )
        try validateStateProgression(
            branch: branch,
            destination: destination,
            postEntry: postEntry,
            identity: identity
        )
    }

    private func validateStateProgression(
        branch: GatheringMovementEntryBranch,
        destination: GatheringMovementEntryDestination,
        postEntry: GatheringPostEntryPromptValidation,
        identity: GatheringReplayStateIdentity
    ) throws {
        try q40State.validateDigest()
        try q41State.validateDigest()
        try q42State.validateDigest()
        try validateStateIdentity(
            q40State,
            version:
            ProductionGatheringActReplayConfiguration
                .firstContinuationQuestionVersion,
            identity: identity
        )
        try validateStateIdentity(
            q41State,
            version:
            ProductionGatheringActReplayConfiguration
                .secondContinuationQuestionVersion,
            identity: identity
        )
        let locationID: LocationID
        let locationCardCode: String
        switch branch {
        case .cellar:
            locationID = destination.locationID
            locationCardCode = destination.branch.locationCardCode
        case .attic:
            locationID = postEntry.hallwayID
            locationCardCode =
                ProductionGatheringActReplayConfiguration.hallwayCardCode
        }
        try validateState(
            q42State,
            expectation: GatheringContinuationStateExpectation(
                version:
                ProductionGatheringActReplayConfiguration
                    .resultingContinuationQuestionVersion,
                remainingActions: branch == .cellar ? 0 : 3,
                locationID: locationID,
                locationCardCode: locationCardCode
            ),
            identity: identity
        )
    }

    private func validateStateIdentity(
        _ state: GatheringActReplayBoardStateEvidence,
        version: Int,
        identity: GatheringReplayStateIdentity
    ) throws {
        guard state.source == .socket,
              state.gameID == identity.gameID,
              state.gameRevision == identity.gameRevision,
              state.playerID == nil,
              state.scenarioSteps == version,
              state.actIDs == [
                  ProductionGatheringActReplayConfiguration.advancedActID,
              ],
              state.investigatorID == identity.investigatorID
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidState
        }
    }

    private func validateState(
        _ state: GatheringActReplayBoardStateEvidence,
        expectation: GatheringContinuationStateExpectation,
        identity: GatheringReplayStateIdentity
    ) throws {
        let locations = state.locations.filter {
            $0.id == expectation.locationID
                && $0.cardCode == expectation.locationCardCode
        }
        guard locations.count == 1 else {
            throw ProductionGatheringActReplayEvidenceError.invalidState
        }
        let location = locations[0]
        try validateStateIdentity(
            state,
            version: expectation.version,
            identity: identity
        )
        guard
            state.investigatorLocationID == expectation.locationID,
            state.remainingActions == expectation.remainingActions,
            location.revealed,
            location.investigatorIDs == [identity.investigatorID]
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidState
        }
    }
}

struct GatheringMovementEntryReplayEvidence: Codable, Equatable, Sendable {
    let branch: GatheringMovementEntryBranch
    let q36Answer: GatheringActReplayAnswerEvidence
    let q36Controller: GatheringActReplayControllerEvidence
    let q37Prompt: GatheringActReplayPromptEvidence
    let q37Answer: GatheringActReplayAnswerEvidence
    let q37Controller: GatheringActReplayControllerEvidence
    let q37State: GatheringActReplayBoardStateEvidence
    let q38Prompt: GatheringActReplayPromptEvidence
    let q38Answer: GatheringActReplayAnswerEvidence
    let q38Controller: GatheringActReplayControllerEvidence
    let q38State: GatheringActReplayBoardStateEvidence
    let q39Prompt: GatheringActReplayPromptEvidence
    let q39State: GatheringActReplayBoardStateEvidence
    let continuation: GatheringContinuationReplayEvidence

    var submittedAnswers: [GatheringActReplayAnswerEvidence] {
        [q36Answer, q37Answer, q38Answer] + continuation.submittedAnswers
    }

    // swiftlint:disable:next function_body_length
    func validate(
        context: GatheringMovementEntryValidationContext
    ) throws {
        let destination = try movementDestination(context: context)
        try q36Answer.validate(
            choice: branch.movementSourceIndex,
            playerID: context.playerID,
            questionVersion:
            ProductionGatheringActReplayConfiguration
                .resultingQuestionVersion
        )
        try q36Controller.validate(
            selectedSourceIndex: branch.movementSourceIndex,
            expectedFocusSourceIndices:
            Array(0 ... branch.movementSourceIndex)
        )
        try q37Prompt.validateForcedAbilityPrompt(
            destination: destination
        )
        try q37Answer.validate(
            choice: 0,
            playerID: context.playerID,
            questionVersion:
            ProductionGatheringActReplayConfiguration
                .forcedAbilityQuestionVersion
        )
        try q37Controller.validate(
            selectedSourceIndex: 0,
            expectedFocusSourceIndices: [0]
        )
        try q38Prompt.validateAssignmentPrompt(
            destination: destination
        )
        try q38Answer.validate(
            choice: 0,
            playerID: context.playerID,
            questionVersion:
            ProductionGatheringActReplayConfiguration
                .assignmentQuestionVersion
        )
        try q38Controller.validate(
            selectedSourceIndex: 0,
            expectedFocusSourceIndices: [0]
        )
        let postEntry = try q39Prompt.validatePostEntryPrompt(
            destination: destination
        )
        try validateBoardTransition(
            q36State: context.q36State,
            identity: context.stateIdentity,
            destination: destination
        )
        try continuation.validate(
            branch: branch,
            destination: destination,
            postEntry: postEntry,
            identity: context.stateIdentity,
            playerID: context.playerID
        )
    }

    private func movementDestination(
        context: GatheringMovementEntryValidationContext
    ) throws -> GatheringMovementEntryDestination {
        try GatheringMovementEntryDestination(
            branch: branch,
            locationID:
            context.q36Prompt.validateMovementPrompt(branch: branch)
        )
    }

    private func validateBoardTransition(
        q36State: GatheringActReplayBoardStateEvidence,
        identity: GatheringReplayStateIdentity,
        destination: GatheringMovementEntryDestination
    ) throws {
        try q37State.validateDigest()
        try q38State.validateDigest()
        try q39State.validateDigest()
        guard q36State.remainingActions == 2,
              q36State.damage == 1,
              q36State.horror == 3
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidState
        }
        try validateEnteredState(
            q37State,
            version:
            ProductionGatheringActReplayConfiguration
                .forcedAbilityQuestionVersion,
            identity: identity,
            destination: destination,
            health: (damage: 1, horror: 3)
        )
        try validateEnteredState(
            q38State,
            version:
            ProductionGatheringActReplayConfiguration
                .assignmentQuestionVersion,
            identity: identity,
            destination: destination,
            health: (damage: 1, horror: 3)
        )
        try validateEnteredState(
            q39State,
            version:
            ProductionGatheringActReplayConfiguration
                .postEntryQuestionVersion,
            identity: identity,
            destination: destination,
            health: (
                damage: branch.resultingDamage,
                horror: branch.resultingHorror
            )
        )
    }

    private func validateEnteredState(
        _ state: GatheringActReplayBoardStateEvidence,
        version: Int,
        identity: GatheringReplayStateIdentity,
        destination: GatheringMovementEntryDestination,
        health: (damage: Int, horror: Int)
    ) throws {
        let locations = state.locations.filter {
            $0.id == destination.locationID
                && $0.cardCode == destination.branch.locationCardCode
        }
        guard locations.count == 1 else {
            throw ProductionGatheringActReplayEvidenceError.invalidState
        }
        let location = locations[0]
        guard state.source == .socket,
              state.gameID == identity.gameID,
              state.gameRevision == identity.gameRevision,
              state.playerID == nil,
              state.scenarioSteps == version,
              state.actIDs == [
                  ProductionGatheringActReplayConfiguration.advancedActID,
              ],
              state.investigatorID == identity.investigatorID,
              state.investigatorLocationID == location.id,
              state.remainingActions == 1,
              state.damage == health.damage,
              state.horror == health.horror,
              location.revealed,
              location.investigatorIDs == [identity.investigatorID],
              state.enemyIDs.isEmpty
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidState
        }
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
    static let currentSchemaVersion = "1.3.0"

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
    let movementEntry: GatheringMovementEntryReplayEvidence?
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
        try movementEntry?.validate(
            context: GatheringMovementEntryValidationContext(
                q36Prompt: q36Prompt,
                q36State: q36State,
                gameID: gameID,
                playerID: playerID,
                investigatorID: investigatorID,
                gameRevision: revisions.game
            )
        )
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
              movementEntry?.branch ==
              configuration.movementEntryBranch,
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
        if let movementEntry {
            _ = try q36Prompt.validateMovementPrompt(
                branch: movementEntry.branch
            )
        } else {
            try q36Prompt.validateResultingPrompt()
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
              q36State.remainingActions == 2,
              q36State.damage == 1,
              q36State.horror == 3,
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
    case invalidQ37
    case invalidQ38
    case invalidQ39
    case invalidQ40
    case invalidQ41
    case invalidQ42
    case invalidState
    case invalidRevisions
    case configurationMismatch
}
