@testable import ArkhamHorrorShared
import Foundation

// swiftlint:disable file_length

struct ProductionCoverUpReplayClues: Codable, Equatable, Sendable {
    let coverUp: Int
    let investigator: Int
    let location: Int

    func subtracting(_ other: Self) -> Self {
        Self(
            coverUp: coverUp - other.coverUp,
            investigator: investigator - other.investigator,
            location: location - other.location
        )
    }
}

struct ProductionCoverUpReplayAnswerEvidence: Codable, Equatable, Sendable {
    let answer: BasicChoiceAnswer
    let canonicalSHA256: String
    let canonicalUTF8: String

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
        let canonicalData = Data(canonicalUTF8.utf8)
        let decoded = try ContractJSON.decode(
            BasicChoiceAnswer.self,
            from: canonicalData
        )
        let encoded = try ContractJSON.encode(answer)
        guard answer == expected,
              decoded == answer,
              encoded == canonicalData,
              canonicalSHA256 == LocaleCatalogLoader.sha256Hex(canonicalData)
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidAnswer
        }
    }
}

struct CoverUpReplayControllerEvidence: Codable, Equatable, Sendable {
    let focusAfterJump: String
    let focusBeforePrimaryAction: String
    let jumpHandled: Bool
    let movedToSelection: Bool
    let primaryActionHandled: Bool
    let selectedSourceIndex: Int
    let submissionResult: String

    func validate(selectedSourceIndex expectedIndex: Int) throws {
        guard jumpHandled,
              focusAfterJump == BoardFocusID.promptChoice(0).rawValue,
              movedToSelection == (expectedIndex != 0),
              focusBeforePrimaryAction
              == BoardFocusID.promptChoice(expectedIndex).rawValue,
              primaryActionHandled,
              selectedSourceIndex == expectedIndex,
              submissionResult == "sentAwaitingSnapshot"
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidController
        }
    }
}

struct ProductionCoverUpReplayPromptEvidence: Codable, Equatable, Sendable {
    let actionableSourceIndices: [Int]
    let canonicalSHA256: String
    let locationID: LocationID
    let playerID: PlayerID
    let skillTestID: SkillTestID
    let sourceIndices: [Int]
    let tag: String
    let treacheryID: TreacheryID
    let version: Int
}

struct ProductionCoverUpReplayResolvedCase: Codable, Equatable, Sendable {
    let attestation: ProductionAssignmentReplayAttestation
    let caseName: String
    let clueDelta: ProductionCoverUpReplayClues
    let cluesAfter: ProductionCoverUpReplayClues
    let cluesBefore: ProductionCoverUpReplayClues
    let gameID: GameID
    let playerID: PlayerID
    let q32Answer: ProductionCoverUpReplayAnswerEvidence
    let q32Controller: CoverUpReplayControllerEvidence
    let q32PromptSHA256: String
    let q33Answer: ProductionCoverUpReplayAnswerEvidence
    let q33Controller: CoverUpReplayControllerEvidence
    let q33Prompt: ProductionCoverUpReplayPromptEvidence
    let resultingQuestionVersion: Int
    let stateAfterSHA256: String
    let stateBeforeSHA256: String
}

struct ProductionCoverUpReplayStaleCase: Codable, Equatable, Sendable {
    let attestation: ProductionAssignmentReplayAttestation
    let caseName: String
    let cluesAfter: ProductionCoverUpReplayClues
    let cluesBefore: ProductionCoverUpReplayClues
    let gameID: GameID
    let playerID: PlayerID
    let promptAfterSHA256: String
    let q32Answer: ProductionCoverUpReplayAnswerEvidence
    let q32Controller: CoverUpReplayControllerEvidence
    let q32PromptSHA256: String
    let q33PromptBefore: ProductionCoverUpReplayPromptEvidence
    let responseStateSHA256: String
    let resultingQuestionVersion: Int
    let staleAnswer: ProductionCoverUpReplayAnswerEvidence
    let staleResponseSHA256: String
    let staleResponseUTF8: String
    let stateAfterSHA256: String
    let stateBeforeSHA256: String
}

struct ProductionCoverUpReplayEvidence: Codable, Equatable, Sendable {
    static let artifactSHA256 =
        "865be796bbecf09c45e4f2af3c78375acc8bf35673c7e1b36256b366afb3befa"
    static let expectedByteCount = 104_104

    private static let schemaVersion = "1.0.0"
    private static let generatedAt = "2026-09-14T23:52:33.598Z"
    private static let backendRevision =
        "38d8b466b635e3c9a18995baccac8b67cb6984cc"
    private static let backendTree =
        "b0114b9ca746a80f4a87eea2e0d164f034227a30"
    private static let backendSourceSHA256 =
        "e2d819cfde5b29ee789242e0d06c236264d11971583efd40535b45f62ad28d80"
    private static let appleRevision =
        "0d96d23a7b0f3d7dc06bec32b99d1208be48a5c3"
    private static let contractRevision = "0.1.40"
    private static let catalogRevision =
        "1.e02c696fd4298f4e59fbf507efe7f1c2"
    private static let checkpointArtifactSHA256 =
        "700fbe8c243b98566a59e971de4d13bb9ccf1e93e4ae835046b6539eee03e752"
    private static let gameRevision =
        "86b648be031dc123b74c33011b2762909f7dbf0b"
    private static let canonicalEnvelopeSHA256 =
        "3fd7c582ee36100de292a4af1a8cf2eacc2c70d1343d7e45e769577267c95902"
    private static let checkpointPlayerID =
        "f532e9d1-e8c2-4a52-b14c-db958fae1aa5"
    private static let checkpointGameSHA256 =
        "951a8b39266c57f9be1da4ca6b21ca20c9c3dd3b5a04c7f21c8110c997afa61d"
    private static let checkpointQueueSHA256 =
        "92f77e475cd0d09861747a351eb025e46ab5acc61d62ffcf0455491f511f7d19"
    private static let q32PromptSHA256 =
        "7ff7e00af7be0a2b933ed1a817e7e2a54d3eaa5ae2bdce17f73f7153e59f23a9"
    private static let q33PromptSHA256 =
        "7c70ba6b40ad8c9965a8a9c8f6644dec60942f73a6db63e3dcb58872832fcd98"
    private static let q33LocationID =
        "4c9a45da-8069-4d10-94d1-451a5e0ae565"
    private static let q33SkillTestID =
        "1bd2b319-9123-4930-b9bb-253791bef36a"
    private static let q33TreacheryID =
        "fef723b4-ae76-4183-9441-b4f3cb8b1eb5"
    private static let staleResponseSHA256 =
        "5d53f501a923ad24796f963798b8073103020a1e39e70c539c65a26f084542ec"
    private static let staleStateSHA256 =
        "d78b864e43d8612c0ae629c341217eb8e62e140de1d78b28e8920026c404cbf8"

    let schemaVersion: String
    let generatedAt: String
    let backendRevision: String
    let appleRevision: String
    let contractRevision: String
    let catalogRevision: String
    let checkpointArtifactSHA256: String
    let use: ProductionCoverUpReplayResolvedCase
    let skip: ProductionCoverUpReplayResolvedCase
    let stale: ProductionCoverUpReplayStaleCase
}

extension ProductionCoverUpReplayEvidence {
    func validateProvenance() throws {
        guard schemaVersion == Self.schemaVersion,
              generatedAt == Self.generatedAt,
              backendRevision == Self.backendRevision,
              appleRevision == Self.appleRevision,
              contractRevision == Self.contractRevision,
              catalogRevision == Self.catalogRevision,
              checkpointArtifactSHA256 == Self.checkpointArtifactSHA256,
              Set([use.gameID, skip.gameID, stale.gameID]).count == 3,
              Set([use.playerID, skip.playerID, stale.playerID]).count == 3
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidMetadata
        }
        guard use.q32PromptSHA256 == Self.q32PromptSHA256,
              skip.q32PromptSHA256 == Self.q32PromptSHA256,
              stale.q32PromptSHA256 == Self.q32PromptSHA256
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidQ32
        }

        try validateQ32(
            attestation: use.attestation,
            gameID: use.gameID,
            playerID: use.playerID,
            answer: use.q32Answer,
            controller: use.q32Controller
        )
        try validateQ32(
            attestation: skip.attestation,
            gameID: skip.gameID,
            playerID: skip.playerID,
            answer: skip.q32Answer,
            controller: skip.q32Controller
        )
        try validateQ32(
            attestation: stale.attestation,
            gameID: stale.gameID,
            playerID: stale.playerID,
            answer: stale.q32Answer,
            controller: stale.q32Controller
        )
    }

    func validateResolvedOutcomes() throws {
        try validateProvenance()
        try validateResolvedCase(
            use,
            caseName: "use-cover-up",
            q33Choice: 0,
            cluesAfter: ProductionCoverUpReplayClues(
                coverUp: 2,
                investigator: 1,
                location: 1
            ),
            clueDelta: ProductionCoverUpReplayClues(
                coverUp: -1,
                investigator: 0,
                location: 0
            )
        )
        try validateResolvedCase(
            skip,
            caseName: "skip-cover-up",
            q33Choice: 1,
            cluesAfter: ProductionCoverUpReplayClues(
                coverUp: 3,
                investigator: 2,
                location: 0
            ),
            clueDelta: ProductionCoverUpReplayClues(
                coverUp: 0,
                investigator: 1,
                location: -1
            )
        )
    }

    func validateStaleOutcome() throws {
        try validateProvenance()
        try validateQ33Prompt(stale.q33PromptBefore, playerID: stale.playerID)
        try stale.staleAnswer.validate(
            choice: 0,
            playerID: stale.playerID,
            questionVersion: 32
        )
        try validateStaleSummary()
        try validateStalePrompt(in: decodeStaleSnapshot())
    }

    private func validateStaleSummary() throws {
        guard stale.caseName == "reject-stale-q32-answer-while-q33-active",
              stale.staleAnswer == stale.q32Answer,
              stale.cluesBefore == ProductionCoverUpReplayClues(
                  coverUp: 3,
                  investigator: 1,
                  location: 1
              ),
              stale.cluesAfter == stale.cluesBefore,
              stale.resultingQuestionVersion == 33,
              stale.promptAfterSHA256 == Self.q33PromptSHA256,
              stale.stateBeforeSHA256 == Self.staleStateSHA256,
              stale.stateAfterSHA256 == Self.staleStateSHA256,
              stale.responseStateSHA256 == Self.staleStateSHA256,
              stale.staleResponseSHA256 == Self.staleResponseSHA256
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidStaleOutcome
        }
    }

    private func decodeStaleSnapshot() throws -> PublicGameSnapshot {
        let responseData = Data(stale.staleResponseUTF8.utf8)
        guard LocaleCatalogLoader.sha256Hex(responseData)
            == stale.staleResponseSHA256
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidStaleOutcome
        }
        let rawResponse = try ContractJSON.decode(JSONValue.self, from: responseData)
        guard case let .object(root) = rawResponse,
              Set(root.keys) == ["tag", "contents"],
              root["tag"] == .string("GameUpdate"),
              let rawSnapshot = root["contents"],
              try ProductionAssignmentReplayCanonicalJSON.promptDigest(rawSnapshot)
              == stale.responseStateSHA256
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidStaleOutcome
        }

        let update = try ContractJSON.decode(
            BoardSnapshotUpdate.self,
            from: responseData
        )
        guard case let .snapshot(snapshot) = update,
              snapshot.id == stale.gameID,
              snapshot.scenarioSteps == stale.resultingQuestionVersion
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidStaleOutcome
        }
        return snapshot
    }

    private func validateQ32(
        attestation: ProductionAssignmentReplayAttestation,
        gameID: GameID,
        playerID: PlayerID,
        answer: ProductionCoverUpReplayAnswerEvidence,
        controller: CoverUpReplayControllerEvidence
    ) throws {
        try validateAttestation(
            attestation,
            gameID: gameID,
            playerID: playerID,
            promptSHA256: Self.q32PromptSHA256
        )
        try answer.validate(
            choice: 0,
            playerID: playerID,
            questionVersion: 32
        )
        try controller.validate(selectedSourceIndex: 0)
    }

    private func validateAttestation(
        _ attestation: ProductionAssignmentReplayAttestation,
        gameID: GameID,
        playerID: PlayerID,
        promptSHA256: String
    ) throws {
        try validateAttestationHeader(attestation, gameID: gameID)
        try validateCheckpoint(
            attestation.validatedCheckpoint,
            promptSHA256: promptSHA256
        )
        try validateBuild(attestation.runningServerBuild)
        try validateReceipt(
            attestation.importReceipt,
            attestation: attestation,
            playerID: playerID
        )
    }

    private func validateAttestationHeader(
        _ attestation: ProductionAssignmentReplayAttestation,
        gameID: GameID
    ) throws {
        guard attestation.schemaVersion
            == ProductionAssignmentReplayAttestation.schemaVersion,
            attestation.gameID == gameID,
            attestation.gameGitRevision == Self.gameRevision,
            attestation.checkpointSHA256 == Self.checkpointArtifactSHA256,
            attestation.canonicalEnvelopeSHA256 == Self.canonicalEnvelopeSHA256
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidAttestation
        }
    }

    private func validateCheckpoint(
        _ checkpoint: AssignmentReplayServerValidatedCheckpoint,
        promptSHA256: String
    ) throws {
        let prompt = checkpoint.prompt
        guard checkpoint.schemaVersion
            == AssignmentReplayServerValidatedCheckpoint.schemaVersion,
            checkpoint.contractSchemaRevision == Self.contractRevision,
            prompt.questionVersion == 32,
            prompt.playerID.codingKey.stringValue == Self.checkpointPlayerID,
            prompt.promptTag == BasicChoiceQuestionKind.windowChooseOne.rawValue,
            prompt.promptSHA256 == promptSHA256,
            checkpoint.checkpointGameSHA256 == Self.checkpointGameSHA256,
            checkpoint.checkpointQueueSHA256 == Self.checkpointQueueSHA256,
            [
                checkpoint.checkpointGameSHA256,
                checkpoint.checkpointQueueSHA256,
                prompt.promptSHA256,
            ].allSatisfy({
                ProductionAssignmentReplayConfiguration.isLowercaseHex(
                    $0,
                    count: 64
                )
            })
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidAttestation
        }
    }

    private func validateBuild(
        _ build: AssignmentReplayServerBuildIdentity
    ) throws {
        guard build.gitRevision == Self.backendRevision,
              build.gitTree == Self.backendTree,
              build.sourceSHA256 == Self.backendSourceSHA256,
              build.sourceClean,
              build.attestation == "git-clean",
              ProductionAssignmentReplayConfiguration.isLowercaseHex(
                  build.sourceSHA256,
                  count: 64
              )
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidAttestation
        }
    }

    private func validateReceipt(
        _ receipt: AssignmentReplayImportReceipt,
        attestation: ProductionAssignmentReplayAttestation,
        playerID: PlayerID
    ) throws {
        guard receipt.playerRemappings.count == 1 else {
            throw ProductionCoverUpReplayEvidenceError.invalidAttestation
        }
        let remapping = receipt.playerRemappings[0]
        let receiptSHA256 = try receipt.computedSHA256()
        let digestsAreValid = [
            attestation.checkpointSHA256,
            attestation.canonicalEnvelopeSHA256,
            receipt.receiptSHA256,
        ].allSatisfy {
            ProductionAssignmentReplayConfiguration.isLowercaseHex(
                $0,
                count: 64
            )
        }
        guard receipt.schemaVersion == AssignmentReplayImportReceipt.schemaVersion,
              receipt.gameID == attestation.gameID,
              receipt.gameGitRevision == attestation.gameGitRevision,
              receipt.backendBuild == attestation.runningServerBuild,
              receipt.checkpointSHA256 == attestation.checkpointSHA256,
              receipt.canonicalEnvelopeSHA256
              == attestation.canonicalEnvelopeSHA256,
              receipt.validatedCheckpoint == attestation.validatedCheckpoint,
              remapping.investigatorID.rawValue.rawValue == "c01001",
              remapping.checkpointPlayerID
              == attestation.validatedCheckpoint.prompt.playerID,
              remapping.importedPlayerID == playerID,
              remapping.livePlayerID == playerID,
              remapping.stateRemapped,
              receipt.receiptSHA256 == receiptSHA256,
              digestsAreValid
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidAttestation
        }
    }

    private func validateResolvedCase(
        _ evidence: ProductionCoverUpReplayResolvedCase,
        caseName: String,
        q33Choice: Int,
        cluesAfter: ProductionCoverUpReplayClues,
        clueDelta: ProductionCoverUpReplayClues
    ) throws {
        try validateQ33Prompt(evidence.q33Prompt, playerID: evidence.playerID)
        try evidence.q33Answer.validate(
            choice: q33Choice,
            playerID: evidence.playerID,
            questionVersion: 33
        )
        try evidence.q33Controller.validate(selectedSourceIndex: q33Choice)
        let stateHashesAreValid = [
            evidence.stateBeforeSHA256,
            evidence.stateAfterSHA256,
        ].allSatisfy {
            ProductionAssignmentReplayConfiguration.isLowercaseHex(
                $0,
                count: 64
            )
        }
        guard evidence.caseName == caseName,
              evidence.cluesBefore == ProductionCoverUpReplayClues(
                  coverUp: 3,
                  investigator: 1,
                  location: 1
              ),
              evidence.cluesAfter == cluesAfter,
              evidence.clueDelta == clueDelta,
              evidence.cluesAfter.subtracting(evidence.cluesBefore)
              == evidence.clueDelta,
              evidence.resultingQuestionVersion == 34,
              evidence.stateBeforeSHA256 != evidence.stateAfterSHA256,
              stateHashesAreValid
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidResolvedOutcome
        }
    }

    private func validateQ33Prompt(
        _ prompt: ProductionCoverUpReplayPromptEvidence,
        playerID: PlayerID
    ) throws {
        guard prompt.actionableSourceIndices == [0, 1],
              prompt.canonicalSHA256 == Self.q33PromptSHA256,
              prompt.locationID.codingKey.stringValue == Self.q33LocationID,
              prompt.playerID == playerID,
              prompt.skillTestID.codingKey.stringValue == Self.q33SkillTestID,
              prompt.sourceIndices == [0, 1],
              prompt.tag == BasicChoiceQuestionKind.windowChooseOne.rawValue,
              prompt.treacheryID.codingKey.stringValue == Self.q33TreacheryID,
              prompt.version == 33
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidQ33
        }
    }

    private func validateStalePrompt(
        in snapshot: PublicGameSnapshot
    ) throws {
        let projection = BoardProjectionBuilder.makeProjection(from: snapshot)
        let (payload, reaction) = try validatedStaleQuestion(in: projection)
        try validateStaleProjection(
            projection,
            payload: payload,
            reaction: reaction
        )
    }

    private func validatedStaleQuestion(
        in projection: BoardProjection
    ) throws -> (
        payload: BasicChoiceQuestionPayload,
        reaction: CoverUpReactionChoice
    ) {
        guard let payload = projection.questions[stale.playerID] else {
            throw ProductionCoverUpReplayEvidenceError.invalidStalePrompt
        }
        let promptSHA256 = try ProductionAssignmentReplayCanonicalJSON
            .promptDigest(payload.rawValue)
        guard projection.questions.count == 1,
              promptSHA256 == stale.q33PromptBefore.canonicalSHA256,
              let question = payload.supportedQuestion,
              question.kind == .windowChooseOne,
              question.choices.map(\.index) == [0, 1]
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidStalePrompt
        }
        guard case let .coverUpReaction(reaction) = question.choices[0].content,
              case let .skipTriggers(skipInvestigatorID) = question.choices[1].content,
              reaction.ability.investigatorID == skipInvestigatorID,
              reaction.ability.cardCode.rawValue == "c01007",
              reaction.treacheryID == stale.q33PromptBefore.treacheryID,
              reaction.locationID == stale.q33PromptBefore.locationID,
              reaction.skillTestID == stale.q33PromptBefore.skillTestID
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidStalePrompt
        }
        return (payload, reaction)
    }

    private func validateStaleProjection(
        _ projection: BoardProjection,
        payload: BasicChoiceQuestionPayload,
        reaction: CoverUpReactionChoice
    ) throws {
        let presentation = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: stale.gameID,
                ownerID: stale.playerID,
                questionVersion: stale.resultingQuestionVersion,
                rawQuestion: payload.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
        let allChoicesAreActionable = presentation.choices.allSatisfy {
            presentation.isChoiceActionable($0, in: projection)
        }
        guard presentation.choices.map(\.index)
            == stale.q33PromptBefore.actionableSourceIndices,
            allChoicesAreActionable,
            let investigator = projection.investigators.first(where: {
                $0.id == reaction.ability.investigatorID
            }),
            investigator.currentLocationID == reaction.locationID,
            let investigatorClues = Self.clueCount(
                in: investigator.tokenCounts
            ),
            let location = projection.locations.first(where: {
                $0.id == reaction.locationID
            }),
            let coverUpClues = projection
            .treacheriesByID[reaction.treacheryID]?.clueCount,
            ProductionCoverUpReplayClues(
                coverUp: coverUpClues,
                investigator: investigatorClues,
                location: location.clueCount
            ) == stale.cluesBefore
        else {
            throw ProductionCoverUpReplayEvidenceError.invalidStalePrompt
        }
    }

    private static func clueCount(
        in summaries: [BoardTokenSummary]
    ) -> Int? {
        let clues = summaries.filter { $0.token == "Clue" }
        guard clues.count == 1 else { return nil }
        return clues[0].count
    }
}

enum ProductionCoverUpReplayEvidenceError: Error {
    case invalidMetadata
    case invalidAttestation
    case invalidAnswer
    case invalidController
    case invalidQ32
    case invalidQ33
    case invalidResolvedOutcome
    case invalidStaleOutcome
    case invalidStalePrompt
}
