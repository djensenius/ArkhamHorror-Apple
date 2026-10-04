@testable import ArkhamHorrorShared
import Foundation

struct GatheringTerminalReplayFixture {
    let evidence: GatheringTerminalReplayEvidence
    let identity: GatheringReplayStateIdentity
    let playerID: PlayerID
    let coverUpID: TreacheryID

    func replacing(
        defeatState: GatheringTerminalStateEvidence? = nil,
        terminalState: GatheringTerminalStateEvidence? = nil
    ) -> GatheringTerminalReplayEvidence {
        GatheringTerminalReplayEvidence(
            steps: evidence.steps,
            defeatState: defeatState ?? evidence.defeatState,
            terminalState: terminalState ?? evidence.terminalState
        )
    }
}

private struct GatheringTerminalStateSpec {
    let scenarioSteps: Int
    let gameState: GameState
    let questionCount: Int
    let horror: Int
    let mentalTrauma: Int
    let defeated: Bool
    let coverUpID: TreacheryID?
}

struct GatheringTerminalReplayFixtureFactory {
    let playerID = BoardTestFixtures.playerID()
    let investigatorID = BoardTestFixtures.investigatorID("c01001")
    let coverUpID = BoardTestFixtures.treacheryID(
        "fef723b4-ae76-4183-9441-b4f3cb8b1eb5"
    )

    func terminalEvidence() throws -> GatheringTerminalReplayFixture {
        let identity = GatheringReplayStateIdentity(
            gameID: BoardTestFixtures.gameID(),
            investigatorID: investigatorID,
            gameRevision: "test"
        )
        let steps = try GatheringTerminalRouteStep.attic.map {
            try terminalStep(expectation: $0, identity: identity)
        }
        let defeat = try terminalState(identity: identity, spec: defeatSpec())
        let terminal = try terminalState(identity: identity, spec: terminalSpec())
        let evidence = GatheringTerminalReplayEvidence(
            steps: steps,
            defeatState: defeat,
            terminalState: terminal
        )
        return GatheringTerminalReplayFixture(
            evidence: evidence,
            identity: identity,
            playerID: playerID,
            coverUpID: coverUpID
        )
    }

    func defeatState(
        scenarioSteps: Int = 68,
        horror: Int = 7,
        coverUpID: TreacheryID? = nil
    ) throws -> GatheringTerminalStateEvidence {
        try terminalState(
            spec: defeatSpec(
                scenarioSteps: scenarioSteps,
                horror: horror,
                coverUpID: coverUpID
            )
        )
    }

    func terminalState(gameState: GameState = .over) throws -> GatheringTerminalStateEvidence {
        try terminalState(spec: terminalSpec(gameState: gameState))
    }

    func defeatStateWithoutCoverUp() throws -> GatheringTerminalStateEvidence {
        try terminalState(
            spec: GatheringTerminalStateSpec(
                scenarioSteps: 68,
                gameState: .active,
                questionCount: 1,
                horror: 7,
                mentalTrauma: 1,
                defeated: true,
                coverUpID: nil
            )
        )
    }

    func replacing<T: Codable>(
        _ value: T,
        at path: [String],
        with replacement: JSONValue
    ) throws -> T {
        var raw = try ContractJSON.decode(JSONValue.self, from: ContractJSON.encode(value))
        raw = try EnemyAttackFixtures.applying(
            operation: "replace",
            path: path.map { Substring($0) },
            replacement: replacement,
            to: raw
        )
        return try ContractJSON.decode(T.self, from: ContractJSON.encode(raw))
    }
}

private extension GatheringTerminalReplayFixtureFactory {
    func defeatSpec(
        scenarioSteps: Int = 68,
        horror: Int = 7,
        coverUpID: TreacheryID? = nil
    ) -> GatheringTerminalStateSpec {
        GatheringTerminalStateSpec(
            scenarioSteps: scenarioSteps,
            gameState: .active,
            questionCount: 1,
            horror: horror,
            mentalTrauma: 1,
            defeated: true,
            coverUpID: coverUpID ?? self.coverUpID
        )
    }

    private func terminalSpec(
        gameState: GameState = .over
    ) -> GatheringTerminalStateSpec {
        GatheringTerminalStateSpec(
            scenarioSteps: 70,
            gameState: gameState,
            questionCount: 0,
            horror: 7,
            mentalTrauma: 2,
            defeated: false,
            coverUpID: nil
        )
    }

    private func terminalStep(
        expectation: GatheringTerminalRouteStep,
        identity: GatheringReplayStateIdentity
    ) throws -> GatheringTerminalReplayStepEvidence {
        let descriptor = GatheringActReplayDescriptorEvidence(
            choice: terminalChoice(role: expectation.role, identity: identity)
        )
        return try GatheringTerminalReplayStepEvidence(
            role: expectation.role,
            prompt: terminalPrompt(expectation: expectation, descriptor: descriptor),
            answer: GatheringActReplayAnswerEvidence(answer: BasicChoiceAnswer(
                choice: descriptor.sourceIndex,
                playerID: playerID,
                questionVersion: expectation.questionVersion
            )),
            controller: terminalController(sourceIndex: descriptor.sourceIndex)
        )
    }

    private func terminalPrompt(
        expectation: GatheringTerminalRouteStep,
        descriptor: GatheringActReplayDescriptorEvidence
    ) -> GatheringActReplayPromptEvidence {
        GatheringActReplayPromptEvidence(
            version: expectation.questionVersion,
            rawTag: expectation.role.expectedRawTag,
            questionKind: expectation.role.expectedQuestionKind.rawValue,
            choiceCount: 1,
            sourceIndices: [0],
            actionableSourceIndices: [0],
            canonicalSHA256: String(repeating: "a", count: 64),
            selectedDescriptor: descriptor,
            governedDescriptors: expectation.questionVersion == 42 ? [descriptor] : nil
        )
    }

    private func terminalController(sourceIndex: Int) -> GatheringActReplayControllerEvidence {
        GatheringActReplayControllerEvidence(
            jumpHandled: true,
            focusAfterJump: BoardFocusID.promptChoice(0).rawValue,
            moveCount: 0,
            allMovesHandled: true,
            focusSourceIndices: [0],
            focusBeforePrimaryAction: BoardFocusID.promptChoice(sourceIndex).rawValue,
            primaryActionHandled: true,
            selectedSourceIndex: sourceIndex,
            submissionResult: "sentAwaitingSnapshot"
        )
    }

    private func terminalChoice(
        role: GatheringTerminalChoiceRole,
        identity: GatheringReplayStateIdentity
    ) -> QuestionPresentation.Choice {
        switch role {
        case .investigateHallway: hallwayInvestigation()
        case .startSkillTest: actorChoice(.startSkillTest, identity: identity)
        case .applySkillTestResults: .init(sourceIndex: 0, kind: .applySkillTestResults)
        case .endTurn: actorChoice(.endTurn, identity: identity)
        case .drawEncounterCard:
            .encounterDeckDraw(actorID: identity.investigatorID.codingKey.stringValue)
        case .discardHandCard:
            entityChoice(.card, id: "00000000-0000-4000-8000-000000000123")
        case .assignHorror:
            entityChoice(
                .investigator,
                id: identity.investigatorID.codingKey.stringValue,
                kind: .assignHorror
            )
        case .resolveTreacheryForcedAbility: coverUpForcedAbility(identity: identity)
        case .continueReading: localizedContinue()
        case .addCampaignCardToDeck:
            entityChoice(.investigator, id: identity.investigatorID.codingKey.stringValue)
        }
    }

    private func hallwayInvestigation() -> QuestionPresentation.Choice {
        .gatheringInvestigation(
            sourceIndex: 0,
            cardCode: ProductionGatheringActReplayConfiguration.hallwayCardCode,
            locationID: "fda9afef-4166-4c9f-962e-eed6e8cbee25"
        )
    }

    private func actorChoice(
        _ kind: QuestionPresentation.ChoiceKind,
        identity: GatheringReplayStateIdentity
    ) -> QuestionPresentation.Choice {
        QuestionPresentation.Choice(
            sourceIndex: 0,
            kind: kind,
            actorID: identity.investigatorID.codingKey.stringValue
        )
    }

    private func entityChoice(
        _ entityKind: QuestionPresentation.EntityKind,
        id: String,
        kind: QuestionPresentation.ChoiceKind = .chooseTarget
    ) -> QuestionPresentation.Choice {
        QuestionPresentation.Choice(
            sourceIndex: 0,
            kind: kind,
            entity: .init(kind: entityKind, id: id)
        )
    }

    private func coverUpForcedAbility(
        identity: GatheringReplayStateIdentity
    ) -> QuestionPresentation.Choice {
        QuestionPresentation.Choice(
            sourceIndex: 0,
            kind: .resolveForcedAbility,
            actorID: identity.investigatorID.codingKey.stringValue,
            entity: .init(kind: .treachery, id: coverUpID.codingKey.stringValue),
            ability: .init(
                cardCode: "c01007",
                index: 2,
                type: .forced,
                actions: [],
                canBeCancelled: true
            ),
            cost: .free
        )
    }

    private func localizedContinue() -> QuestionPresentation.Choice {
        QuestionPresentation.Choice(
            sourceIndex: 0,
            kind: .localizedLabel,
            label: .init(kind: .embeddedI18n, text: "$continue")
        )
    }

    private func terminalState(
        identity: GatheringReplayStateIdentity? = nil,
        spec: GatheringTerminalStateSpec? = nil
    ) throws -> GatheringTerminalStateEvidence {
        let identity = identity ?? GatheringReplayStateIdentity(
            gameID: BoardTestFixtures.gameID(),
            investigatorID: investigatorID,
            gameRevision: "test"
        )
        let spec = spec ?? GatheringTerminalStateSpec(
            scenarioSteps: 70,
            gameState: .over,
            questionCount: 0,
            horror: 7,
            mentalTrauma: 2,
            defeated: false,
            coverUpID: nil
        )
        var snapshot = BoardTestFixtures.snapshot(
            investigators: [identity.investigatorID: investigator(spec: spec)],
            playerOrder: [identity.investigatorID],
            activeInvestigatorID: identity.investigatorID,
            leadInvestigatorID: identity.investigatorID,
            gameState: spec.gameState,
            treacheryValues: spec.coverUpID.map { [$0: coverUpObject(id: $0)] } ?? [:],
            questionCount: spec.questionCount
        )
        snapshot = try snapshotWithScenarioSteps(spec.scenarioSteps, in: snapshot)
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        return try GatheringTerminalStateEvidence(
            observation: AssignmentReplayAuthoritativeObservation(
                source: .socket,
                gameID: identity.gameID,
                gameRevision: identity.gameRevision,
                playerID: nil,
                snapshot: snapshot,
                projection: projection
            ),
            investigatorID: identity.investigatorID,
            coverUpTreacheryID: spec.coverUpID
        )
    }

    private func investigator(spec: GatheringTerminalStateSpec) -> Investigator {
        BoardTestFixtures.investigator(
            id: investigatorID,
            mentalTrauma: spec.mentalTrauma,
            defeated: spec.defeated,
            tokens: [
                TokenCount(token: "Damage", count: 1),
                TokenCount(token: "Horror", count: spec.horror),
            ],
            playerID: playerID
        )
    }

    private func coverUpObject(id: TreacheryID) -> JSONValue {
        .object([
            "id": .string(id.codingKey.stringValue),
            "cardCode": .string("c01007"),
            "tokens": .array([.array([.string("Clue"), .number(.integer(3))])]),
        ])
    }

    private func snapshotWithScenarioSteps(
        _ scenarioSteps: Int,
        in snapshot: PublicGameSnapshot
    ) throws -> PublicGameSnapshot {
        var value = try ContractJSON.decode(JSONValue.self, from: ContractJSON.encode(snapshot))
        value = try EnemyAttackFixtures.applying(
            operation: "replace",
            path: ["scenarioSteps"].map { Substring($0) },
            replacement: .number(.integer(Int64(scenarioSteps))),
            to: value
        )
        return try ContractJSON.decode(PublicGameSnapshot.self, from: ContractJSON.encode(value))
    }
}
