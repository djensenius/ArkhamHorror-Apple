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
