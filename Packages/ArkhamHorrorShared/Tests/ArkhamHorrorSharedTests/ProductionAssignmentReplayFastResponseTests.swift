@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    @Test("A fast authoritative resolution can clear the claim before send returns")
    func fastAuthoritativeResolutionReturnsRetryable() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.setSendGated(true)
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )
        let identity = try #require(
            model.basicChoicePresentation(for: gameID)?.identity
        )

        let submission = Task {
            await model.submitBasicChoice(identity, choiceIndex: 0)
        }
        await connection.waitUntilSendPending(1)
        let resolved = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1
        )
        try await connection.enqueue(.event(.message(
            ContractJSON.encode(resolved)
        )))
        await connection.waitUntilAwaitingNextEvent()
        #expect(model.basicChoiceActions[gameID] == nil)

        await connection.resumeOldestSend(with: .success(()))
        #expect(await submission.value == .retryableFailure)
        #expect(await connection.sentData.count == 1)
        guard case let .live(projection) = model.liveGameState(for: gameID)
        else {
            throw TestFailure()
        }
        #expect(
            projection.counters.scenarioSteps
                == envelope.game.scenarioSteps + 1
        )
    }
}
