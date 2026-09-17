@testable import ArkhamHorrorShared
import Foundation
import Testing

// swiftlint:disable file_length
private enum AtticQ42EvidenceRole {
    case atticMovement
    case hallwayInvestigation
    case cellarMovement
}

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
            _ = try q39PromptEvidence(destination: destination)
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

    @Test("Post-entry successor prompts bind exact Q40 through Q42 roles")
    func postEntrySuccessorPrompts() throws {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        for branch in [
            GatheringMovementEntryBranch.cellar,
            .attic,
        ] {
            try q40PromptEvidence(branch: branch)
                .validateFirstContinuationPrompt(
                    branch: branch,
                    investigatorID: investigatorID
                )
            try q41PromptEvidence(branch: branch)
                .validateSecondContinuationPrompt(
                    branch: branch,
                    investigatorID: investigatorID
                )
            try q42PromptEvidence(branch: branch)
                .validateResultingContinuationPrompt(
                    branch: branch,
                    investigatorID: investigatorID
                )
        }

        try q42PromptEvidence(
            branch: .attic,
            atticRoleOrder: [
                .cellarMovement,
                .hallwayInvestigation,
                .atticMovement,
            ]
        ).validateResultingContinuationPrompt(
            branch: .attic,
            investigatorID: investigatorID
        )

        #expect(
            throws:
            ProductionGatheringActReplayEvidenceError.invalidQ42
        ) {
            try q42PromptEvidence(
                branch: .attic,
                actionableSourceIndices: Array(0 ..< 11)
            ).validateResultingContinuationPrompt(
                branch: .attic,
                investigatorID: investigatorID
            )
        }
    }

    @Test("Seven-card Attic Q42 keeps every source index actionable")
    func sevenCardAtticQ42() throws {
        try q42PromptEvidence(
            branch: .attic,
            atticHandCardCount: 7
        ).validateResultingContinuationPrompt(
            branch: .attic,
            investigatorID: BoardTestFixtures.investigatorID("c01001")
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
        let investigation = GatheringActReplayDescriptorEvidence(
            choice: .gatheringInvestigation(
                cardCode: destination.branch.locationCardCode,
                locationID:
                destination.locationID.codingKey.stringValue
            )
        )
        let hallway = GatheringActReplayDescriptorEvidence(
            choice: .gatheringHallwayMovement(locationID: hallwayID)
        )
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
            selectedDescriptor:
            destination.branch == .cellar ? investigation : hallway,
            governedDescriptors: [investigation, hallway]
        )
    }

    func q40PromptEvidence(
        branch: GatheringMovementEntryBranch
    ) -> GatheringActReplayPromptEvidence {
        let kind: QuestionPresentation.ChoiceKind = switch branch {
        case .cellar:
            .startSkillTest
        case .attic:
            .endTurn
        }
        let questionKind: QuestionPresentation.Kind = switch branch {
        case .cellar:
            .chooseOne
        case .attic:
            .playerWindowChooseOne
        }
        let rawTag: BasicChoiceQuestionKind = switch branch {
        case .cellar:
            .chooseOne
        case .attic:
            .playerWindowChooseOne
        }
        return GatheringActReplayPromptEvidence(
            version:
            ProductionGatheringActReplayConfiguration
                .firstContinuationQuestionVersion,
            rawTag: rawTag.rawValue,
            questionKind: questionKind.rawValue,
            choiceCount: 1,
            sourceIndices: [0],
            actionableSourceIndices: [0],
            canonicalSHA256: String(repeating: "a", count: 64),
            selectedDescriptor: GatheringActReplayDescriptorEvidence(
                choice: QuestionPresentation.Choice(
                    sourceIndex: 0,
                    kind: kind,
                    actorID: "c01001",
                    entity: nil,
                    label: nil,
                    ability: nil,
                    cost: nil
                )
            )
        )
    }

    func q41PromptEvidence(
        branch: GatheringMovementEntryBranch
    ) -> GatheringActReplayPromptEvidence {
        let choice: QuestionPresentation.Choice = switch branch {
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
            .encounterDeckDraw(actorID: "c01001")
        }
        return GatheringActReplayPromptEvidence(
            version:
            ProductionGatheringActReplayConfiguration
                .secondContinuationQuestionVersion,
            rawTag: BasicChoiceQuestionKind.chooseOne.rawValue,
            questionKind: QuestionPresentation.Kind.chooseOne.rawValue,
            choiceCount: 1,
            sourceIndices: [0],
            actionableSourceIndices: [0],
            canonicalSHA256: String(repeating: "b", count: 64),
            selectedDescriptor:
            GatheringActReplayDescriptorEvidence(choice: choice)
        )
    }

    func q42PromptEvidence(
        branch: GatheringMovementEntryBranch,
        actionableSourceIndices: [Int]? = nil,
        atticHandCardCount: Int = 6,
        atticRoleOrder: [AtticQ42EvidenceRole] = [
            .atticMovement,
            .hallwayInvestigation,
            .cellarMovement,
        ]
    ) -> GatheringActReplayPromptEvidence {
        let choices: [QuestionPresentation.Choice] = switch branch {
        case .cellar:
            [
                QuestionPresentation.Choice(
                    sourceIndex: 0,
                    kind: .endTurn,
                    actorID: "c01001",
                    entity: nil,
                    label: nil,
                    ability: nil,
                    cost: nil
                ),
            ]
        case .attic:
            atticQ42Choices(
                handCardCount: atticHandCardCount,
                roleOrder: atticRoleOrder
            )
        }
        let sourceIndices = choices.map(\.sourceIndex)
        return GatheringActReplayPromptEvidence(
            version:
            ProductionGatheringActReplayConfiguration
                .resultingContinuationQuestionVersion,
            rawTag:
            BasicChoiceQuestionKind.playerWindowChooseOne.rawValue,
            questionKind:
            QuestionPresentation.Kind.playerWindowChooseOne.rawValue,
            choiceCount: choices.count,
            sourceIndices: sourceIndices,
            actionableSourceIndices:
            actionableSourceIndices ?? sourceIndices,
            canonicalSHA256: String(repeating: "c", count: 64),
            selectedDescriptor: nil,
            governedDescriptors: choices.map(
                GatheringActReplayDescriptorEvidence.init(choice:)
            )
        )
    }

    // swiftlint:disable:next function_body_length
    func atticQ42Choices(
        handCardCount: Int,
        roleOrder: [AtticQ42EvidenceRole]
    ) -> [QuestionPresentation.Choice] {
        let cardIDs = (0 ..< handCardCount).map {
            String(format: "00000000-0000-4000-8000-%012d", $0)
        }
        var choices = [
            QuestionPresentation.Choice(
                sourceIndex: 0,
                kind: .gainResource,
                actorID: "c01001",
                entity: nil,
                label: nil,
                ability: nil,
                cost: nil
            ),
            QuestionPresentation.Choice(
                sourceIndex: 1,
                kind: .drawCard,
                actorID: "c01001",
                entity: nil,
                label: nil,
                ability: nil,
                cost: nil
            ),
        ] + cardIDs.enumerated().map { offset, cardID in
            QuestionPresentation.Choice(
                sourceIndex: offset + 2,
                kind: .chooseTarget,
                actorID: nil,
                entity: .init(kind: .card, id: cardID),
                label: nil,
                ability: nil,
                cost: nil
            )
        }
        choices.append(
            QuestionPresentation.Choice(
                sourceIndex: choices.count,
                kind: .endTurn,
                actorID: "c01001",
                entity: nil,
                label: nil,
                ability: nil,
                cost: nil
            )
        )
        let firstRoleSourceIndex = choices.count
        choices += roleOrder.enumerated().map { offset, role in
            let sourceIndex = offset + firstRoleSourceIndex
            return switch role {
            case .atticMovement:
                .gatheringLocationMovement(
                    sourceIndex: sourceIndex,
                    cardCode: "c01113",
                    locationID:
                    "dbaa2d2e-4ceb-44b2-a554-e5fa370e7882",
                    cost: .action(1)
                )
            case .hallwayInvestigation:
                .gatheringInvestigation(
                    sourceIndex: sourceIndex,
                    cardCode:
                    ProductionGatheringActReplayConfiguration
                        .hallwayCardCode,
                    locationID:
                    "fda9afef-4166-4c9f-962e-eed6e8cbee25"
                )
            case .cellarMovement:
                .gatheringMovement(
                    sourceIndex: sourceIndex,
                    cardCode: "c01114",
                    locationID:
                    "a3497b9f-796b-406d-aeb4-9b96fa9f4905"
                )
            }
        }
        return choices
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
