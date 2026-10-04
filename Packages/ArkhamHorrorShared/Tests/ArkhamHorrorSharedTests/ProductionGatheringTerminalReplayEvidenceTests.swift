@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Gathering terminal replay validator")
struct GatheringTerminalReplayEvidenceTests {
    private let playerID = BoardTestFixtures.playerID()
    private let investigatorID = BoardTestFixtures.investigatorID("c01001")
    private let coverUpID = BoardTestFixtures.treacheryID(
        "fef723b4-ae76-4183-9441-b4f3cb8b1eb5"
    )

    @Test("Terminal route evidence accepts Q42 through Q70 and terminal states")
    func validTerminalEvidence() throws {
        let fixture = try terminalEvidence()

        try fixture.evidence.validate(
            promptIdentity: fixture.identity,
            playerID: playerID
        )
        #expect(fixture.evidence.steps.map(\.prompt.version) == Array(42 ... 70))
        #expect(fixture.evidence.defeatState.scenarioSteps == 68)
        #expect(fixture.evidence.terminalState.scenarioSteps == 70)
        #expect(fixture.evidence.terminalState.gameStateSummary == "Over")
    }

    @Test("Terminal route rejects count, role, version, and actionability drift")
    func terminalRouteDriftFailsClosed() throws {
        let fixture = try terminalEvidence()

        try expectTerminalReplayRejected(
            GatheringTerminalReplayEvidence(
                steps: Array(fixture.evidence.steps.dropLast()),
                defeatState: fixture.evidence.defeatState,
                terminalState: fixture.evidence.terminalState
            ),
            identity: fixture.identity
        )

        try expectTerminalReplayRejected(
            replacing(
                fixture.evidence,
                at: ["steps", "0", "role"],
                with: .string(GatheringTerminalChoiceRole.endTurn.rawValue)
            ),
            identity: fixture.identity
        )

        try expectTerminalReplayRejected(
            replacing(
                fixture.evidence,
                at: ["steps", "1", "prompt", "version"],
                with: .number(.integer(999))
            ),
            identity: fixture.identity
        )

        try expectTerminalReplayRejected(
            replacing(
                fixture.evidence,
                at: ["steps", "0", "prompt", "actionableSourceIndices"],
                with: .array([])
            ),
            identity: fixture.identity
        )
    }

    @Test("Terminal state digest rejects byte tampering")
    func terminalStateDigestTamperingFailsClosed() throws {
        let fixture = try terminalEvidence()
        try fixture.evidence.defeatState.validateDigest()

        let tampered: GatheringTerminalStateEvidence = try replacing(
            fixture.evidence.defeatState,
            at: ["summaryCanonicalSHA256"],
            with: .string(String(repeating: "0", count: 64))
        )
        #expect(
            throws: ProductionGatheringActReplayEvidenceError.digestMismatch
        ) {
            try tampered.validateDigest()
        }
    }

    @Test("Terminal replay rejects defeat, terminal, and missing Cover Up state drift")
    func terminalStateDriftFailsClosed() throws {
        let fixture = try terminalEvidence()

        try expectTerminalReplayRejected(
            GatheringTerminalReplayEvidence(
                steps: fixture.evidence.steps,
                defeatState: try terminalState(
                    identity: fixture.identity,
                    scenarioSteps: 69,
                    gameState: .active,
                    questionCount: 1,
                    horror: 7,
                    mentalTrauma: 1,
                    defeated: true,
                    coverUpID: coverUpID
                ),
                terminalState: fixture.evidence.terminalState
            ),
            identity: fixture.identity
        )

        try expectTerminalReplayRejected(
            GatheringTerminalReplayEvidence(
                steps: fixture.evidence.steps,
                defeatState: try terminalState(
                    identity: fixture.identity,
                    scenarioSteps: 68,
                    gameState: .active,
                    questionCount: 1,
                    horror: 6,
                    mentalTrauma: 1,
                    defeated: true,
                    coverUpID: coverUpID
                ),
                terminalState: fixture.evidence.terminalState
            ),
            identity: fixture.identity
        )

        try expectTerminalReplayRejected(
            GatheringTerminalReplayEvidence(
                steps: fixture.evidence.steps,
                defeatState: fixture.evidence.defeatState,
                terminalState: try terminalState(
                    identity: fixture.identity,
                    scenarioSteps: 70,
                    gameState: .active,
                    questionCount: 0,
                    horror: 7,
                    mentalTrauma: 2,
                    defeated: false,
                    coverUpID: nil
                )
            ),
            identity: fixture.identity
        )

        try expectTerminalReplayRejected(
            GatheringTerminalReplayEvidence(
                steps: fixture.evidence.steps,
                defeatState: try terminalState(
                    identity: fixture.identity,
                    scenarioSteps: 68,
                    gameState: .active,
                    questionCount: 1,
                    horror: 7,
                    mentalTrauma: 1,
                    defeated: true,
                    coverUpID: nil
                ),
                terminalState: fixture.evidence.terminalState
            ),
            identity: fixture.identity
        )
    }

    private func terminalEvidence() throws -> (
        evidence: GatheringTerminalReplayEvidence,
        identity: GatheringReplayStateIdentity
    ) {
        let identity = GatheringReplayStateIdentity(
            gameID: BoardTestFixtures.gameID(),
            investigatorID: investigatorID,
            gameRevision: "test"
        )
        return try (
            GatheringTerminalReplayEvidence(
                steps: GatheringTerminalRouteStep.attic.map {
                    try terminalStep(
                        expectation: $0,
                        identity: identity
                    )
                },
                defeatState: terminalState(
                    identity: identity,
                    scenarioSteps: 68,
                    gameState: .active,
                    questionCount: 1,
                    horror: 7,
                    mentalTrauma: 1,
                    defeated: true,
                    coverUpID: coverUpID
                ),
                terminalState: terminalState(
                    identity: identity,
                    scenarioSteps: 70,
                    gameState: .over,
                    questionCount: 0,
                    horror: 7,
                    mentalTrauma: 2,
                    defeated: false,
                    coverUpID: nil
                )
            ),
            identity
        )
    }

    private func terminalStep(
        expectation: GatheringTerminalRouteStep,
        identity: GatheringReplayStateIdentity
    ) throws -> GatheringTerminalReplayStepEvidence {
        let descriptor = GatheringActReplayDescriptorEvidence(
            choice: terminalChoice(
                role: expectation.role,
                identity: identity,
                sourceIndex: 0
            )
        )
        return try GatheringTerminalReplayStepEvidence(
            role: expectation.role,
            prompt: GatheringActReplayPromptEvidence(
                version: expectation.questionVersion,
                rawTag: expectation.role.expectedRawTag,
                questionKind: expectation.role.expectedQuestionKind.rawValue,
                choiceCount: 1,
                sourceIndices: [0],
                actionableSourceIndices: [0],
                canonicalSHA256: String(repeating: "a", count: 64),
                selectedDescriptor: descriptor,
                governedDescriptors: expectation.questionVersion == 42 ? [descriptor] : nil
            ),
            answer: GatheringActReplayAnswerEvidence(answer: BasicChoiceAnswer(
                choice: descriptor.sourceIndex,
                playerID: playerID,
                questionVersion: expectation.questionVersion
            )),
            controller: GatheringActReplayControllerEvidence(
                jumpHandled: true,
                focusAfterJump: BoardFocusID.promptChoice(0).rawValue,
                moveCount: 0,
                allMovesHandled: true,
                focusSourceIndices: [0],
                focusBeforePrimaryAction:
                BoardFocusID.promptChoice(descriptor.sourceIndex).rawValue,
                primaryActionHandled: true,
                selectedSourceIndex: descriptor.sourceIndex,
                submissionResult: "sentAwaitingSnapshot"
            )
        )
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func terminalChoice(
        role: GatheringTerminalChoiceRole,
        identity: GatheringReplayStateIdentity,
        sourceIndex: Int
    ) -> QuestionPresentation.Choice {
        switch role {
        case .investigateHallway:
            .gatheringInvestigation(
                sourceIndex: sourceIndex,
                cardCode: ProductionGatheringActReplayConfiguration.hallwayCardCode,
                locationID: "fda9afef-4166-4c9f-962e-eed6e8cbee25"
            )
        case .startSkillTest:
            QuestionPresentation.Choice(
                sourceIndex: sourceIndex,
                kind: .startSkillTest,
                actorID: identity.investigatorID.codingKey.stringValue
            )
        case .applySkillTestResults:
            QuestionPresentation.Choice(
                sourceIndex: sourceIndex,
                kind: .applySkillTestResults
            )
        case .endTurn:
            QuestionPresentation.Choice(
                sourceIndex: sourceIndex,
                kind: .endTurn,
                actorID: identity.investigatorID.codingKey.stringValue
            )
        case .drawEncounterCard:
            .encounterDeckDraw(actorID: identity.investigatorID.codingKey.stringValue)
        case .discardHandCard:
            QuestionPresentation.Choice(
                sourceIndex: sourceIndex,
                kind: .chooseTarget,
                entity: .init(
                    kind: .card,
                    id: "00000000-0000-4000-8000-000000000123"
                )
            )
        case .assignHorror:
            QuestionPresentation.Choice(
                sourceIndex: sourceIndex,
                kind: .assignHorror,
                entity: .init(
                    kind: .investigator,
                    id: identity.investigatorID.codingKey.stringValue
                )
            )
        case .resolveTreacheryForcedAbility:
            QuestionPresentation.Choice(
                sourceIndex: sourceIndex,
                kind: .resolveForcedAbility,
                actorID: identity.investigatorID.codingKey.stringValue,
                entity: .init(
                    kind: .treachery,
                    id: coverUpID.codingKey.stringValue
                ),
                ability: .init(
                    cardCode: "c01007",
                    index: 2,
                    type: .forced,
                    actions: [],
                    canBeCancelled: true
                ),
                cost: .free
            )
        case .continueReading:
            QuestionPresentation.Choice(
                sourceIndex: sourceIndex,
                kind: .localizedLabel,
                label: .init(kind: .embeddedI18n, text: "$continue")
            )
        case .addCampaignCardToDeck:
            QuestionPresentation.Choice(
                sourceIndex: sourceIndex,
                kind: .chooseTarget,
                entity: .init(
                    kind: .investigator,
                    id: identity.investigatorID.codingKey.stringValue
                )
            )
        }
    }

    private func terminalState(
        identity: GatheringReplayStateIdentity,
        scenarioSteps: Int,
        gameState: GameState,
        questionCount: Int,
        horror: Int,
        mentalTrauma: Int,
        defeated: Bool,
        coverUpID: TreacheryID?
    ) throws -> GatheringTerminalStateEvidence {
        var snapshot = BoardTestFixtures.snapshot(
            investigators: [
                identity.investigatorID: BoardTestFixtures.investigator(
                    id: identity.investigatorID,
                    mentalTrauma: mentalTrauma,
                    defeated: defeated,
                    tokens: [
                        TokenCount(token: "Damage", count: 1),
                        TokenCount(token: "Horror", count: horror),
                    ],
                    playerID: playerID
                ),
            ],
            playerOrder: [identity.investigatorID],
            activeInvestigatorID: identity.investigatorID,
            leadInvestigatorID: identity.investigatorID,
            gameState: gameState,
            treacheryValues: coverUpID.map { [
                $0: coverUpObject(id: $0),
            ] } ?? [:],
            questionCount: questionCount
        )
        snapshot = try snapshotWithScenarioSteps(scenarioSteps, in: snapshot)
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
            coverUpTreacheryID: coverUpID
        )
    }

    private func coverUpObject(id: TreacheryID) -> JSONValue {
        .object([
            "id": .string(id.codingKey.stringValue),
            "cardCode": .string("c01007"),
            "tokens": .array([
                .array([.string("Clue"), .number(.integer(3))]),
            ]),
        ])
    }

    private func snapshotWithScenarioSteps(
        _ scenarioSteps: Int,
        in snapshot: PublicGameSnapshot
    ) throws -> PublicGameSnapshot {
        var value = try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(snapshot)
        )
        value = try EnemyAttackFixtures.applying(
            operation: "replace",
            path: ["scenarioSteps"].map { Substring($0) },
            replacement: .number(.integer(Int64(scenarioSteps))),
            to: value
        )
        return try ContractJSON.decode(
            PublicGameSnapshot.self,
            from: ContractJSON.encode(value)
        )
    }

    private func expectTerminalReplayRejected(
        _ evidence: GatheringTerminalReplayEvidence,
        identity: GatheringReplayStateIdentity
    ) throws {
        #expect(
            throws: ProductionGatheringActReplayEvidenceError
                .invalidTerminalReplay
        ) {
            try evidence.validate(promptIdentity: identity, playerID: playerID)
        }
    }

    private func replacing<T: Codable>(
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
