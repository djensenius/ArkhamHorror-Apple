@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("Production Gathering act replay mechanics")
// swiftlint:disable:next type_name
struct ProductionGatheringActReplayMechanicsTests {
    @Test("Attestation accepts known Gathering prompt kinds")
    func attestedGatheringPromptKind() throws {
        let playerID = BoardTestFixtures.playerID()
        let prompt = AssignmentReplayServerValidatedPrompt(
            questionVersion: 34,
            playerID: playerID,
            promptTag: BasicChoiceQuestionKind.playerWindowChooseOne.rawValue,
            promptSHA256: String(repeating: "a", count: 64)
        )

        try prompt.validate()
        #expect(
            throws: ProductionAssignmentReplayError
                .serverAttestationMismatch
        ) {
            try AssignmentReplayServerValidatedPrompt(
                questionVersion: 34,
                playerID: playerID,
                promptTag: "FuturePrompt",
                promptSHA256: String(repeating: "a", count: 64)
            ).validate()
        }
    }

    @Test("Canonical answers retain exact source index, player, and version")
    func canonicalAnswer() throws {
        let playerID = BoardTestFixtures.playerID()
        let answer = BasicChoiceAnswer(
            choice: 12,
            playerID: playerID,
            questionVersion: 34
        )
        let evidence = try GatheringActReplayAnswerEvidence(answer: answer)

        try evidence.validate(
            choice: 12,
            playerID: playerID,
            questionVersion: 34
        )
        #expect(
            evidence.canonicalSHA256 ==
                LocaleCatalogLoader.sha256Hex(
                    Data(evidence.canonicalUTF8.utf8)
                )
        )
    }

    @Test("Controller evidence preserves the actionable focus path")
    func controllerFocusPath() throws {
        let evidence = GatheringActReplayControllerEvidence(
            jumpHandled: true,
            focusAfterJump: BoardFocusID.promptChoice(0).rawValue,
            moveCount: 4,
            allMovesHandled: true,
            focusSourceIndices: [0, 1, 8, 9, 12],
            focusBeforePrimaryAction:
            BoardFocusID.promptChoice(12).rawValue,
            primaryActionHandled: true,
            selectedSourceIndex: 12,
            submissionResult: "sentAwaitingSnapshot"
        )

        try evidence.validate(
            selectedSourceIndex: 12,
            expectedFocusSourceIndices: [0, 1, 8, 9, 12]
        )
        #expect(
            throws:
            ProductionGatheringActReplayEvidenceError.invalidController
        ) {
            try evidence.validate(
                selectedSourceIndex: 12,
                expectedFocusSourceIndices: Array(0 ... 12)
            )
        }
    }

    @Test("Q36 evidence requires every source index to remain actionable")
    func q36CompleteActionability() throws {
        let complete = try q36PromptEvidence(
            actionableSourceIndices: Array(0 ..< 12)
        )
        try complete.validateResultingPrompt()

        let incomplete = try q36PromptEvidence(
            actionableSourceIndices: [0]
        )
        #expect(
            throws:
            ProductionGatheringActReplayEvidenceError.invalidQ36
        ) {
            try incomplete.validateResultingPrompt()
        }
    }

    @Test("Movement branches bind exact Q36 through Q39 identities")
    func movementEntryBranches() throws {
        for branch in [
            GatheringMovementEntryBranch.cellar,
            .attic,
        ] {
            let destination = try GatheringMovementEntryDestination(
                branch: branch,
                locationID:
                q36MovementPromptEvidence(branch: branch)
                    .validateMovementPrompt(branch: branch)
            )
            try q37PromptEvidence(branch: branch)
                .validateForcedAbilityPrompt(
                    destination: destination
                )
            try q38PromptEvidence(branch: branch)
                .validateAssignmentPrompt(
                    destination: destination
                )
            try q39PromptEvidence(destination: destination)
                .validatePostEntryPrompt(destination: destination)
        }
    }

    @Test("Movement replay scenarios produce branch-specific evidence names")
    func movementEntryScenarioNames() {
        #expect(
            ProductionAssignmentReplayScenario.gatheringCellarEntry
                .gatheringMovementEntryBranch == .cellar
        )
        #expect(
            ProductionAssignmentReplayScenario.gatheringAtticEntry
                .gatheringMovementEntryBranch == .attic
        )
        #expect(
            GatheringActReplayCoordinatorDriver.evidenceName(
                for: .gatheringCellarEntry
            ) == "gathering-cellar-entry.json"
        )
        #expect(
            GatheringActReplayCoordinatorDriver.evidenceName(
                for: .gatheringAtticEntry
            ) == "gathering-attic-entry.json"
        )
    }

    @Test("Board summaries bind their authoritative source and revision")
    func authoritativeBoardSummary() throws {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let playerID = BoardTestFixtures.playerID()
        let snapshot = BoardTestFixtures.snapshot(
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    playerID: playerID
                ),
            ]
        )
        let evidence = try GatheringActReplayBoardStateEvidence(
            observation: AssignmentReplayAuthoritativeObservation(
                source: .socket,
                gameID: snapshot.id,
                gameRevision: snapshot.git,
                playerID: nil,
                snapshot: snapshot,
                projection: BoardProjectionBuilder.makeProjection(
                    from: snapshot
                )
            ),
            investigatorID: investigatorID
        )

        #expect(evidence.source == .socket)
        #expect(evidence.gameID == snapshot.id)
        #expect(evidence.gameRevision == snapshot.git)
        #expect(evidence.playerID == nil)
        try evidence.validateDigest()

        var object = try #require(
            JSONSerialization.jsonObject(
                with: ContractJSON.encode(evidence)
            ) as? [String: Any]
        )
        object["source"] = AssignmentReplayObservationSource.rest.rawValue
        let altered = try ContractJSON.decode(
            GatheringActReplayBoardStateEvidence.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(
            throws:
            ProductionGatheringActReplayEvidenceError.digestMismatch
        ) {
            try altered.validateDigest()
        }
    }
}

private extension ProductionGatheringActReplayMechanicsTests {
    func rawQuestionTag(in fixtureName: String) throws -> String {
        let url = try #require(
            Bundle.module.url(
                forResource: fixtureName,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        let value = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        )
        let object = try #require(value as? [String: Any])
        return try #require(object["tag"] as? String)
    }

    func q36PromptEvidence(
        actionableSourceIndices: [Int]
    ) throws -> GatheringActReplayPromptEvidence {
        let sourceIndices = Array(0 ..< 12)
        return try ContractJSON.decode(
            GatheringActReplayPromptEvidence.self,
            from: JSONSerialization.data(
                withJSONObject: [
                    "version":
                        ProductionGatheringActReplayConfiguration
                        .resultingQuestionVersion,
                    "rawTag":
                        BasicChoiceQuestionKind
                        .playerWindowChooseOne.rawValue,
                    "questionKind":
                        QuestionPresentation.Kind
                        .playerWindowChooseOne.rawValue,
                    "choiceCount": sourceIndices.count,
                    "sourceIndices": sourceIndices,
                    "actionableSourceIndices": actionableSourceIndices,
                    "canonicalSHA256": String(repeating: "a", count: 64),
                    "selectedDescriptor": NSNull(),
                ]
            )
        )
    }

    func q36MovementPromptEvidence(
        branch: GatheringMovementEntryBranch
    ) throws -> GatheringActReplayPromptEvidence {
        let sourceIndices = Array(0 ..< 12)
        let locationID = movementEntryFixtureLocationID(for: branch)
        return try GatheringActReplayPromptEvidence(
            version:
            ProductionGatheringActReplayConfiguration
                .resultingQuestionVersion,
            rawTag: rawQuestionTag(in: "question-gathering-movement"),
            questionKind:
            QuestionPresentation.Kind.playerWindowChooseOne.rawValue,
            choiceCount: sourceIndices.count,
            sourceIndices: sourceIndices,
            actionableSourceIndices: sourceIndices,
            canonicalSHA256:
            ProductionGatheringActReplayConfiguration
                .movementPromptSHA256,
            selectedDescriptor: GatheringActReplayDescriptorEvidence(
                choice: branch.movementDescriptor(locationID: locationID)
            )
        )
    }

    func q37PromptEvidence(
        branch: GatheringMovementEntryBranch
    ) throws -> GatheringActReplayPromptEvidence {
        let locationID = movementEntryFixtureLocationID(for: branch)
        return try GatheringActReplayPromptEvidence(
            version:
            ProductionGatheringActReplayConfiguration
                .forcedAbilityQuestionVersion,
            rawTag: rawQuestionTag(
                in: branch == .cellar
                    ? "question-gathering-cellar-entry-forced"
                    : "question-gathering-attic-entry-forced"
            ),
            questionKind: QuestionPresentation.Kind.windowChooseOne.rawValue,
            choiceCount: 1,
            sourceIndices: [0],
            actionableSourceIndices: [0],
            canonicalSHA256: branch.q37PromptSHA256,
            selectedDescriptor: GatheringActReplayDescriptorEvidence(
                choice: branch.forcedAbilityDescriptor(
                    locationID: locationID
                )
            )
        )
    }

    func q38PromptEvidence(
        branch: GatheringMovementEntryBranch
    ) throws -> GatheringActReplayPromptEvidence {
        let locationID = movementEntryFixtureLocationID(for: branch)
        return try GatheringActReplayPromptEvidence(
            version:
            ProductionGatheringActReplayConfiguration
                .assignmentQuestionVersion,
            rawTag: rawQuestionTag(
                in: branch == .cellar
                    ? "question-gathering-cellar-damage-assignment"
                    : "question-gathering-attic-horror-assignment"
            ),
            questionKind: QuestionPresentation.Kind.chooseOne.rawValue,
            choiceCount: 1,
            sourceIndices: [0],
            actionableSourceIndices: [0],
            canonicalSHA256: branch.q38PromptSHA256,
            selectedDescriptor: GatheringActReplayDescriptorEvidence(
                choice: branch.assignmentDescriptor
            ),
            governedSourceEntityKind:
            QuestionPresentation.EntityKind.location.rawValue,
            governedSourceEntityID: locationID,
            governedSourceCardCode: branch.locationCardCode
        )
    }

    func q39PromptEvidence(
        destination: GatheringMovementEntryDestination,
        actionableSourceIndices: [Int] = Array(0 ..< 11)
    ) -> GatheringActReplayPromptEvidence {
        let hallwayID = "fda9afef-4166-4c9f-962e-eed6e8cbee25"
        return GatheringActReplayPromptEvidence(
            version:
            ProductionGatheringActReplayConfiguration
                .postEntryQuestionVersion,
            rawTag:
            BasicChoiceQuestionKind.playerWindowChooseOne.rawValue,
            questionKind:
            QuestionPresentation.Kind.playerWindowChooseOne.rawValue,
            choiceCount: 11,
            sourceIndices: Array(0 ..< 11),
            actionableSourceIndices: actionableSourceIndices,
            canonicalSHA256: destination.branch.q39PromptSHA256,
            selectedDescriptor: nil,
            governedDescriptors: [
                GatheringActReplayDescriptorEvidence(
                    choice: .gatheringInvestigation(
                        cardCode: destination.branch.locationCardCode,
                        locationID:
                        destination.locationID.codingKey.stringValue
                    )
                ),
                GatheringActReplayDescriptorEvidence(
                    choice: .gatheringHallwayMovement(locationID: hallwayID)
                ),
            ]
        )
    }

    func movementEntryFixtureLocationID(
        for branch: GatheringMovementEntryBranch
    ) -> String {
        switch branch {
        case .cellar:
            "a3497b9f-796b-406d-aeb4-9b96fa9f4905"
        case .attic:
            "dbaa2d2e-4ceb-44b2-a554-e5fa370e7882"
        }
    }
}
