@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    @Test("Roland reaction and Skip submit exact source indices and Q32 version")
    func rolandReactionAnswersAreExact() async throws {
        for choiceIndex in [0, 1] {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            let envelope = try rolandReactionEnvelope(loadGetGame())
            let connection = FakeGameSocketConnection()
            await connection.enqueueSendResult(.success(()))
            let gameID = await startChoiceSession(
                model: model, fakes: fakes, envelope: envelope, connection: connection
            )
            let presentation = try #require(model.basicChoicePresentation(for: gameID))
            let projection = try #require(
                model.liveGameStates[gameID]?.lastKnownProjection
            )
            #expect(presentation.questionVersion == 32)
            let choice = try #require(
                presentation.choices.first { $0.index == choiceIndex }
            )
            #expect(presentation.isChoiceActionable(choice, in: projection))
            #expect(
                await model.submitBasicChoice(
                    presentation.identity, choiceIndex: choiceIndex
                ) == .sentAwaitingSnapshot
            )
            #expect(await connection.sentData == [
                rolandReactionAnswer(
                    choice: choiceIndex, identity: presentation.identity
                ),
            ])
        }
    }

    @Test("An older Roland reaction cannot submit after a newer snapshot")
    func staleRolandReactionFailsClosed() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let question = try RolandReactionFixtures.value()
        let envelope = try rolandReactionEnvelope(loadGetGame())
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let staleIdentity = try #require(
            model.basicChoicePresentation(for: gameID)?.identity
        )

        let update = try snapshotUpdate(
            from: envelope,
            scenarioSteps: 33,
            replacingQuestionWith: question
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(update))))
        await connection.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.questionVersion == 33)
        #expect(current.identity != staleIdentity)
        #expect(
            await model.submitBasicChoice(staleIdentity, choiceIndex: 0) == .staleQuestion
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("A failed Roland reaction retries only on the current connection")
    func rolandReactionRetryReconcilesConnectionIdentity() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try rolandReactionEnvelope(loadGetGame())
        let firstConnection = FakeGameSocketConnection()
        await firstConnection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: firstConnection
        )
        let oldIdentity = try #require(
            model.basicChoicePresentation(for: gameID)?.identity
        )
        #expect(
            await model.submitBasicChoice(oldIdentity, choiceIndex: 0) == .retryableFailure
        )

        let replacement = FakeGameSocketConnection()
        await fakes.socketFactory.enqueueConnectResult(.success(replacement))
        await fakes.service.enqueueGetGameResult(.success(envelope))
        await firstConnection.enqueue(.failure(GameSocketTransportError()))
        await replacement.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.identity != oldIdentity)
        #expect(current.actionPhase == .retryable(.transportFailure))

        await replacement.enqueueSendResult(.success(()))
        #expect(await model.retryBasicChoice(current.identity) == .sentAwaitingSnapshot)
        #expect(await firstConnection.sentData == [
            rolandReactionAnswer(choice: 0, identity: oldIdentity),
        ])
        #expect(await replacement.sentData == [
            rolandReactionAnswer(choice: 0, identity: current.identity),
        ])
    }

    private func rolandReactionEnvelope(
        _ base: GetGameEnvelope
    ) throws -> GetGameEnvelope {
        try envelopeReplacingQuestion(
            base,
            scenarioSteps: 32,
            replacingQuestionWith: RolandReactionFixtures.value()
        )
    }

    private func rolandReactionAnswer(
        choice: Int, identity: BasicChoicePromptIdentity
    ) -> Data {
        Data(
            """
            {"contents":{"choice":\(choice),\
            "playerId":"\(identity.ownerID.rawValue.uuidString.lowercased())",\
            "questionVersion":\(identity.questionVersion)},"tag":"Answer"}
            """.utf8
        )
    }
}
