@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("Board controller input dispatch gate")
struct BoardControllerInputDispatchGateTests {
    @Test("Presenting the game log suspends controller dispatch until dismissal")
    func gameLogSuspendsControllerDispatchUntilDismissal() throws {
        let owner = BoardControllerInputOwner()
        let coordinator = ControllerInputOwnershipCoordinator()
        coordinator.claim(owner)
        var submitted: [Int] = []
        var handleCalls = 0
        let controller = try BoardCommandController(
            projection: BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot()),
            prompt: actionablePrompt(),
            onChoice: { submitted.append($0) }
        )
        #expect(controller.handle(.command(.jumpToActivePrompt)))
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        let dispatchPrimaryAction = {
            BoardControllerInputDispatchGate.dispatch(
                .command(.primaryAction), owner: owner, coordinator: coordinator
            ) {
                handleCalls += 1
                controller.handle($0)
            }
        }

        #expect(dispatchPrimaryAction())
        #expect(handleCalls == 1)
        #expect(submitted == [0])
        owner.isSuspended = true
        #expect(!dispatchPrimaryAction())
        #expect(handleCalls == 1)
        #expect(submitted == [0])
        #expect(controller.coordinator.currentFocus == BoardFocusID.promptChoice(0))
        owner.isSuspended = false
        #expect(dispatchPrimaryAction())
        #expect(handleCalls == 2)
        #expect(submitted == [0, 0])
    }

    private func actionablePrompt() throws -> BasicChoicePromptPresentation {
        let url = try #require(Bundle.module.url(
            forResource: "question-choose-one", withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self, from: Data(contentsOf: url)
        )
        return BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(), ownerID: BoardTestFixtures.playerID(),
                questionVersion: 1, rawQuestion: payload.rawValue,
                sessionAttemptID: nil, connectionID: nil
            ),
            question: payload.state, readOnlyReason: nil, actionPhase: nil,
            actionChoiceIndex: nil, serverFeedback: nil
        )
    }
}
