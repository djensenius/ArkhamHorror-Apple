@testable import ArkhamHorrorShared
import Foundation

// swiftlint:disable file_length

enum GatheringTerminalChoiceRole: String, Codable, Equatable, Sendable {
    case investigateHallway
    case startSkillTest
    case applySkillTestResults
    case endTurn
    case drawEncounterCard
    case discardHandCard
    case assignHorror
    case resolveTreacheryForcedAbility
    case continueReading
    case addCampaignCardToDeck

    // swiftlint:disable:next function_body_length
    func matches(
        _ descriptor: GatheringActReplayDescriptorEvidence,
        investigatorID: InvestigatorID
    ) -> Bool {
        switch self {
        case .investigateHallway:
            descriptor.kind ==
                QuestionPresentation.ChoiceKind.investigate.rawValue
                && descriptor.actorID ==
                investigatorID.codingKey.stringValue
                && descriptor.entityKind ==
                QuestionPresentation.EntityKind.location.rawValue
                && descriptor.abilityCardCode ==
                ProductionGatheringActReplayConfiguration.hallwayCardCode
        case .startSkillTest:
            descriptor.kind ==
                QuestionPresentation.ChoiceKind.startSkillTest.rawValue
                && descriptor.actorID ==
                investigatorID.codingKey.stringValue
        case .applySkillTestResults:
            descriptor.kind ==
                QuestionPresentation.ChoiceKind
                .applySkillTestResults.rawValue
                && descriptor.actorID == nil
        case .endTurn:
            descriptor.kind ==
                QuestionPresentation.ChoiceKind.endTurn.rawValue
                && descriptor.actorID ==
                investigatorID.codingKey.stringValue
        case .drawEncounterCard:
            descriptor.kind ==
                QuestionPresentation.ChoiceKind.drawEncounterCard.rawValue
                && descriptor.actorID ==
                investigatorID.codingKey.stringValue
        case .discardHandCard:
            descriptor.kind ==
                QuestionPresentation.ChoiceKind.chooseTarget.rawValue
                && descriptor.actorID == nil
                && descriptor.entityKind ==
                QuestionPresentation.EntityKind.card.rawValue
        case .assignHorror:
            descriptor.kind ==
                QuestionPresentation.ChoiceKind.assignHorror.rawValue
                && descriptor.actorID == nil
                && descriptor.entityKind ==
                QuestionPresentation.EntityKind.investigator.rawValue
                && descriptor.entityID ==
                investigatorID.codingKey.stringValue
        case .resolveTreacheryForcedAbility:
            descriptor.kind ==
                QuestionPresentation.ChoiceKind.resolveForcedAbility.rawValue
                && descriptor.actorID ==
                investigatorID.codingKey.stringValue
                && descriptor.entityKind ==
                QuestionPresentation.EntityKind.treachery.rawValue
                && descriptor.abilityCardCode == "c01007"
                && descriptor.abilityIndex == 2
                && descriptor.abilityType ==
                QuestionPresentation.AbilityType.forced.rawValue
                && descriptor.abilityActions == []
                && descriptor.abilityCanBeCancelled == true
                && descriptor.costKind == "free"
        case .continueReading:
            descriptor.kind ==
                QuestionPresentation.ChoiceKind.localizedLabel.rawValue
        case .addCampaignCardToDeck:
            descriptor.kind ==
                QuestionPresentation.ChoiceKind.chooseTarget.rawValue
                && descriptor.entityKind ==
                QuestionPresentation.EntityKind.investigator.rawValue
                && descriptor.entityID ==
                investigatorID.codingKey.stringValue
        }
    }

    var expectedRawTag: String {
        switch self {
        case .investigateHallway, .endTurn:
            BasicChoiceQuestionKind.playerWindowChooseOne.rawValue
        case .startSkillTest, .applySkillTestResults,
             .drawEncounterCard, .discardHandCard:
            BasicChoiceQuestionKind.chooseOne.rawValue
        case .assignHorror:
            "QuestionWithSource"
        case .resolveTreacheryForcedAbility:
            BasicChoiceQuestionKind.windowChooseOne.rawValue
        case .continueReading:
            BasicChoiceQuestionKind.read.rawValue
        case .addCampaignCardToDeck:
            "QuestionLabel"
        }
    }

    var expectedQuestionKind: QuestionPresentation.Kind {
        switch self {
        case .investigateHallway, .endTurn:
            .playerWindowChooseOne
        case .resolveTreacheryForcedAbility:
            .windowChooseOne
        case .continueReading:
            .read
        case .startSkillTest, .applySkillTestResults,
             .drawEncounterCard, .discardHandCard,
             .assignHorror, .addCampaignCardToDeck:
            .chooseOne
        }
    }
}

struct GatheringTerminalRouteStep: Equatable, Sendable {
    let questionVersion: Int
    let role: GatheringTerminalChoiceRole

    static let attic: [Self] = [
        Self(questionVersion: 42, role: .investigateHallway),
        Self(questionVersion: 43, role: .startSkillTest),
        Self(questionVersion: 44, role: .applySkillTestResults),
        Self(questionVersion: 45, role: .investigateHallway),
        Self(questionVersion: 46, role: .startSkillTest),
        Self(questionVersion: 47, role: .applySkillTestResults),
        Self(questionVersion: 48, role: .investigateHallway),
        Self(questionVersion: 49, role: .startSkillTest),
        Self(questionVersion: 50, role: .applySkillTestResults),
        Self(questionVersion: 51, role: .endTurn),
        Self(questionVersion: 52, role: .drawEncounterCard),
        Self(questionVersion: 53, role: .investigateHallway),
        Self(questionVersion: 54, role: .startSkillTest),
        Self(questionVersion: 55, role: .applySkillTestResults),
        Self(questionVersion: 56, role: .investigateHallway),
        Self(questionVersion: 57, role: .startSkillTest),
        Self(questionVersion: 58, role: .applySkillTestResults),
        Self(questionVersion: 59, role: .investigateHallway),
        Self(questionVersion: 60, role: .startSkillTest),
        Self(questionVersion: 61, role: .applySkillTestResults),
        Self(questionVersion: 62, role: .endTurn),
        Self(questionVersion: 63, role: .discardHandCard),
        Self(questionVersion: 64, role: .drawEncounterCard),
        Self(questionVersion: 65, role: .startSkillTest),
        Self(questionVersion: 66, role: .applySkillTestResults),
        Self(questionVersion: 67, role: .assignHorror),
        Self(questionVersion: 68, role: .resolveTreacheryForcedAbility),
        Self(questionVersion: 69, role: .continueReading),
        Self(questionVersion: 70, role: .addCampaignCardToDeck),
    ]
}

struct GatheringTerminalReplayStepEvidence: Codable, Equatable, Sendable {
    let role: GatheringTerminalChoiceRole
    let prompt: GatheringActReplayPromptEvidence
    let answer: GatheringActReplayAnswerEvidence
    let controller: GatheringActReplayControllerEvidence

    func validate(
        expectation: GatheringTerminalRouteStep,
        investigatorID: InvestigatorID,
        playerID: PlayerID
    ) throws {
        guard role == expectation.role,
              prompt.version == expectation.questionVersion,
              prompt.rawTag == role.expectedRawTag,
              prompt.questionKind == role.expectedQuestionKind.rawValue,
              prompt.choiceCount == prompt.sourceIndices.count,
              prompt.sourceIndices == Array(0 ..< prompt.choiceCount),
              Set(prompt.sourceIndices).count == prompt.choiceCount,
              let descriptor = prompt.selectedDescriptor,
              prompt.actionableSourceIndices.contains(
                  descriptor.sourceIndex
              ),
              role.matches(
                  descriptor,
                  investigatorID: investigatorID
              ),
              expectation.questionVersion == 42
              ? prompt.governedDescriptors != nil
              : prompt.governedDescriptors == nil,
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  prompt.canonicalSHA256,
                  count: 64
              ),
              let selectedPosition = prompt.actionableSourceIndices
              .firstIndex(of: descriptor.sourceIndex)
        else {
            throw ProductionGatheringActReplayEvidenceError
                .invalidTerminalReplay
        }
        try answer.validate(
            choice: descriptor.sourceIndex,
            playerID: playerID,
            questionVersion: expectation.questionVersion
        )
        try controller.validate(
            selectedSourceIndex: descriptor.sourceIndex,
            expectedFocusSourceIndices: Array(
                prompt.actionableSourceIndices[...selectedPosition]
            )
        )
    }
}

private struct GatheringTerminalStatePayload: Codable, Equatable, Sendable {
    let source: AssignmentReplayObservationSource
    let gameID: GameID
    let gameRevision: String
    let playerID: PlayerID?
    let scenarioSteps: Int
    let gameStateSummary: String
    let pendingPromptCount: Int
    let investigatorID: InvestigatorID
    let damage: Int
    let horror: Int
    let mentalTrauma: Int
    let defeated: Bool
    let eliminated: Bool
    let coverUpTreacheryID: TreacheryID?
    let coverUpCardCode: String?
    let coverUpClueCount: Int?
}

struct GatheringTerminalStateEvidence: Codable, Equatable, Sendable {
    let source: AssignmentReplayObservationSource
    let gameID: GameID
    let gameRevision: String
    let playerID: PlayerID?
    let scenarioSteps: Int
    let gameStateSummary: String
    let pendingPromptCount: Int
    let investigatorID: InvestigatorID
    let damage: Int
    let horror: Int
    let mentalTrauma: Int
    let defeated: Bool
    let eliminated: Bool
    let coverUpTreacheryID: TreacheryID?
    let coverUpCardCode: String?
    let coverUpClueCount: Int?
    let summaryCanonicalSHA256: String

    // swiftlint:disable:next function_body_length
    init(
        observation: AssignmentReplayAuthoritativeObservation,
        investigatorID: InvestigatorID,
        coverUpTreacheryID: TreacheryID?
    ) throws {
        guard let investigator = observation.projection.investigators
            .first(where: { $0.id == investigatorID })
        else {
            throw ProductionGatheringActReplayEvidenceError.invalidState
        }
        let coverUp = coverUpTreacheryID.flatMap { treacheryID in
            observation.projection.treacheriesByID[treacheryID]
        }
        let payload = GatheringTerminalStatePayload(
            source: observation.source,
            gameID: observation.gameID,
            gameRevision: observation.gameRevision,
            playerID: observation.playerID,
            scenarioSteps: observation.projection.counters.scenarioSteps,
            gameStateSummary:
            observation.projection.counters.gameStateSummary,
            pendingPromptCount:
            observation.projection.counters.pendingPromptCount,
            investigatorID: investigatorID,
            damage: Self.tokenCount(
                "Damage",
                in: investigator.tokenCounts
            ),
            horror: Self.tokenCount(
                "Horror",
                in: investigator.tokenCounts
            ),
            mentalTrauma: investigator.mentalTrauma,
            defeated: investigator.defeated,
            eliminated: investigator.eliminated,
            coverUpTreacheryID: coverUp?.id,
            coverUpCardCode: coverUp?.cardCode.rawValue,
            coverUpClueCount: coverUp?.clueCount
        )
        source = payload.source
        gameID = payload.gameID
        gameRevision = payload.gameRevision
        playerID = payload.playerID
        scenarioSteps = payload.scenarioSteps
        gameStateSummary = payload.gameStateSummary
        pendingPromptCount = payload.pendingPromptCount
        self.investigatorID = payload.investigatorID
        damage = payload.damage
        horror = payload.horror
        mentalTrauma = payload.mentalTrauma
        defeated = payload.defeated
        eliminated = payload.eliminated
        self.coverUpTreacheryID = payload.coverUpTreacheryID
        coverUpCardCode = payload.coverUpCardCode
        coverUpClueCount = payload.coverUpClueCount
        summaryCanonicalSHA256 =
            try ProductionAssignmentReplayCanonicalJSON.digest(payload)
    }

    func validateDigest() throws {
        let payload = GatheringTerminalStatePayload(
            source: source,
            gameID: gameID,
            gameRevision: gameRevision,
            playerID: playerID,
            scenarioSteps: scenarioSteps,
            gameStateSummary: gameStateSummary,
            pendingPromptCount: pendingPromptCount,
            investigatorID: investigatorID,
            damage: damage,
            horror: horror,
            mentalTrauma: mentalTrauma,
            defeated: defeated,
            eliminated: eliminated,
            coverUpTreacheryID: coverUpTreacheryID,
            coverUpCardCode: coverUpCardCode,
            coverUpClueCount: coverUpClueCount
        )
        guard try summaryCanonicalSHA256 ==
            ProductionAssignmentReplayCanonicalJSON.digest(payload)
        else {
            throw ProductionGatheringActReplayEvidenceError.digestMismatch
        }
    }

    private static func tokenCount(
        _ token: String,
        in counts: [BoardTokenSummary]
    ) -> Int {
        counts.first(where: { $0.token == token })?.count ?? 0
    }
}

struct GatheringTerminalReplayEvidence: Codable, Equatable, Sendable {
    let steps: [GatheringTerminalReplayStepEvidence]
    let defeatState: GatheringTerminalStateEvidence
    let terminalState: GatheringTerminalStateEvidence

    var submittedAnswers: [GatheringActReplayAnswerEvidence] {
        steps.map(\.answer)
    }

    // swiftlint:disable:next function_body_length
    func validate(
        promptIdentity: GatheringReplayStateIdentity,
        playerID: PlayerID
    ) throws {
        guard steps.count == GatheringTerminalRouteStep.attic.count else {
            throw ProductionGatheringActReplayEvidenceError
                .invalidTerminalReplay
        }
        for (step, expectation) in zip(
            steps,
            GatheringTerminalRouteStep.attic
        ) {
            try step.validate(
                expectation: expectation,
                investigatorID: promptIdentity.investigatorID,
                playerID: playerID
            )
        }
        guard let coverUpIDText = steps.first(where: {
            $0.role == .resolveTreacheryForcedAbility
        })?.prompt.selectedDescriptor?.entityID,
            let coverUpID = TreacheryID(
                codingKey: AnyCodingKey(stringValue: coverUpIDText)
            )
        else {
            throw ProductionGatheringActReplayEvidenceError
                .invalidTerminalReplay
        }
        try defeatState.validateDigest()
        try terminalState.validateDigest()
        guard defeatState.source == .socket,
              defeatState.gameID == promptIdentity.gameID,
              defeatState.gameRevision == promptIdentity.gameRevision,
              defeatState.playerID == nil,
              defeatState.scenarioSteps == 68,
              defeatState.gameStateSummary == "Active",
              defeatState.pendingPromptCount == 1,
              defeatState.investigatorID ==
              promptIdentity.investigatorID,
              defeatState.damage == 1,
              defeatState.horror == 7,
              defeatState.mentalTrauma == 1,
              defeatState.defeated,
              !defeatState.eliminated,
              defeatState.coverUpTreacheryID == coverUpID,
              defeatState.coverUpCardCode == "c01007",
              defeatState.coverUpClueCount == 3,
              terminalState.source == .socket,
              terminalState.gameID == promptIdentity.gameID,
              terminalState.gameRevision == promptIdentity.gameRevision,
              terminalState.playerID == nil,
              terminalState.scenarioSteps == 70,
              terminalState.gameStateSummary == "Over",
              terminalState.pendingPromptCount == 0,
              terminalState.investigatorID ==
              promptIdentity.investigatorID,
              terminalState.damage == 1,
              terminalState.horror == 7,
              terminalState.mentalTrauma == 2,
              !terminalState.defeated,
              !terminalState.eliminated,
              terminalState.coverUpTreacheryID == nil,
              terminalState.coverUpCardCode == nil,
              terminalState.coverUpClueCount == nil
        else {
            throw ProductionGatheringActReplayEvidenceError
                .invalidTerminalReplay
        }
    }
}
