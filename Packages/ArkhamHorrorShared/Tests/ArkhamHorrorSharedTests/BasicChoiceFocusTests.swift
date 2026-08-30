@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Basic choice focus")
struct BasicChoiceFocusTests {
    private func actionablePrompt() throws -> BasicChoicePromptPresentation {
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: Data(
                """
                {"tag":"ChooseOne","choices":[
                  {"tag":"EndTurnButton","investigatorId":"c01001","messages":[]},
                  {"tag":"FutureChoice","messages":[]}
                ]}
                """.utf8
            )
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: BoardTestFixtures.playerID(),
                questionVersion: 3,
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
    }

    private func retryablePrompt() throws -> BasicChoicePromptPresentation {
        let prompt = try actionablePrompt()
        return BasicChoicePromptPresentation(
            identity: prompt.identity,
            question: prompt.question,
            readOnlyReason: nil,
            actionPhase: .retryable(.outcomeUncertain),
            actionChoiceIndex: 0,
            serverFeedback: nil
        )
    }

    @Test("Jump targets the first actionable choice and primary action preserves its exact index")
    func promptJumpAndPrimaryAction() throws {
        var submitted: [Int] = []
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let controller = try BoardCommandController(
            projection: projection,
            prompt: actionablePrompt(),
            onChoice: { submitted.append($0) }
        )

        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0])

        controller.updateChoiceHandler { submitted.append($0 + 10) }
        #expect(controller.handle(.command(.primaryAction)))
        #expect(submitted == [0, 10])
    }

    @Test("Prompt back and removal restore deterministic board focus")
    func promptFocusRestoration() throws {
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let controller = try BoardCommandController(
            projection: projection, prompt: actionablePrompt()
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.handle(.reservedBack))
        #expect(controller.coordinator.currentFocus == BoardFocusID.scenarioHeader)

        #expect(controller.handle(.command(.jumpToActivePrompt)))
        controller.applyPrompt(nil)
        #expect(controller.coordinator.currentFocus == BoardFocusID.scenarioHeader)
    }

    @Test("Toggle prompt surface enters and leaves the actionable prompt")
    func togglePromptSurface() throws {
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let controller = try BoardCommandController(
            projection: projection, prompt: actionablePrompt()
        )
        #expect(controller.handle(.command(.togglePromptSurface)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        #expect(controller.handle(.command(.togglePromptSurface)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.scenarioHeader)
    }

    @Test("Retry state has deterministic semantic focus and controller activation")
    func retryFocusAndActivation() throws {
        var retries = 0
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let controller = try BoardCommandController(
            projection: projection,
            prompt: retryablePrompt(),
            onRetry: { retries += 1 }
        )

        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptRetry)
        #expect(controller.handle(.command(.primaryAction)))
        #expect(retries == 1)
    }
}
