@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Mulligan prompt focus")
struct BasicChoiceMulliganFocusTests {
    private func payload() throws -> BasicChoiceQuestionPayload {
        let url = try #require(
            Bundle.module.url(
                forResource: "question-mulligan",
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: Data(contentsOf: url)
        )
    }

    private func cardID(_ raw: String) throws -> WireCardID {
        try #require(WireCardID(codingKey: AnyCodingKey(stringValue: raw)))
    }

    private func playerCard(id: WireCardID, code: String) -> JSONValue {
        .object([
            "tag": .string("PlayerCard"),
            "contents": .object([
                "id": .string(id.codingKey.stringValue),
                "cardCode": .string(code),
            ]),
        ])
    }

    @Test("Focus skips an unresolved done label without reindexing card choices")
    // swiftlint:disable:next function_body_length
    func focusPreservesMulliganSourceIndices() throws {
        let payload = try payload()
        let question = try #require(payload.supportedQuestion)
        let ownerID = BoardTestFixtures.playerID()
        let cardIDs = try [
            cardID("00000000-0000-0000-0000-0000000003c0"),
            cardID("00000000-0000-0000-0000-0000000003c1"),
            cardID("00000000-0000-0000-0000-0000000003c2"),
        ]
        let cards = zip(cardIDs, ["c01018", "c01023", "c01030"]).map {
            playerCard(id: $0.0, code: $0.1)
        }
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    hand: cards,
                    playerID: ownerID
                ),
            ],
            playerOrder: [investigatorID],
            activeInvestigatorID: investigatorID,
            leadInvestigatorID: investigatorID,
            cardValues: Dictionary(uniqueKeysWithValues: zip(cardIDs, cards))
        ))
        let promptKey = BasicChoicePromptKey(
            gameID: BoardTestFixtures.gameID(),
            ownerID: ownerID,
            questionVersion: 4,
            rawQuestion: payload.rawValue
        )
        let catalogRetry = BasicChoiceCatalogRetryPresentation(
            profileID: UUID(),
            catalogGeneration: 2,
            promptKey: promptKey
        )
        let presentation = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: promptKey.gameID,
                ownerID: promptKey.ownerID,
                questionVersion: promptKey.questionVersion,
                rawQuestion: promptKey.rawQuestion,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            choiceLabelResolutions: [0: .unavailable(.catalog(.transportFailure))],
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil,
            catalogRetry: catalogRetry
        )
        var submitted: [Int] = []
        var retried: [BasicChoiceCatalogRetryPresentation] = []
        let controller = BoardCommandController(
            projection: projection,
            prompt: presentation,
            onChoice: { submitted.append($0) },
            onCatalogRetry: { retried.append($0) }
        )

        #expect(question.choices.map(\.index) == [0, 1, 2, 3])
        #expect(!controller.coordinator.graph.contains(BoardFocusID.promptChoice(0)))
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptChoice(1)))
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptChoice(2)))
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptChoice(3)))
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptCatalogRetry))

        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(1))
        #expect(!controller.activatePromptChoice(0))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(controller.activatePromptChoice(3))
        #expect(submitted == [1, 3])

        #expect(controller.activatePromptCatalogRetry())
        #expect(retried == [catalogRetry])
    }

    @Test("Choice retry and catalog retry remain independently controller-accessible")
    // swiftlint:disable:next function_body_length
    func choiceAndCatalogRetriesCoexist() throws {
        let payload = try payload()
        let promptKey = BasicChoicePromptKey(
            gameID: BoardTestFixtures.gameID(),
            ownerID: BoardTestFixtures.playerID(),
            questionVersion: 4,
            rawQuestion: payload.rawValue
        )
        let catalogRetry = BasicChoiceCatalogRetryPresentation(
            profileID: UUID(),
            catalogGeneration: 2,
            promptKey: promptKey
        )
        let presentation = BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: promptKey.gameID,
                ownerID: promptKey.ownerID,
                questionVersion: promptKey.questionVersion,
                rawQuestion: promptKey.rawQuestion,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: payload.state,
            choiceLabelResolutions: [0: .unavailable(.catalog(.transportFailure))],
            readOnlyReason: nil,
            actionPhase: .retryable(.transportFailure),
            actionChoiceIndex: 1,
            serverFeedback: nil,
            catalogRetry: catalogRetry
        )
        var choiceRetryCount = 0
        var catalogRetries: [BasicChoiceCatalogRetryPresentation] = []
        let controller = BoardCommandController(
            projection: BoardProjectionBuilder.makeProjection(
                from: BoardTestFixtures.snapshot()
            ),
            prompt: presentation,
            onRetry: { choiceRetryCount += 1 },
            onCatalogRetry: { catalogRetries.append($0) }
        )

        #expect(controller.coordinator.graph.contains(BoardFocusID.promptRetry))
        #expect(controller.coordinator.graph.contains(BoardFocusID.promptCatalogRetry))
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptRetry)
        #expect(controller.handle(
            focusID: BoardFocusID.promptCatalogRetry,
            .command(.primaryAction)
        ))
        #expect(catalogRetries == [catalogRetry])
        #expect(controller.handle(
            focusID: BoardFocusID.promptRetry,
            .command(.primaryAction)
        ))
        #expect(choiceRetryCount == 1)
    }
}
