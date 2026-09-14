@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    @Test("Cover Up reaction and Skip submit exact source indices and Q33 version")
    func coverUpReactionAnswersAreExact() async throws {
        for choiceIndex in [0, 1] {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            let envelope = try coverUpReactionEnvelope(loadGetGame())
            let connection = FakeGameSocketConnection()
            await connection.enqueueSendResult(.success(()))
            let gameID = await startChoiceSession(
                model: model, fakes: fakes, envelope: envelope, connection: connection
            )
            let presentation = try #require(model.basicChoicePresentation(for: gameID))
            let projection = try #require(
                model.liveGameStates[gameID]?.lastKnownProjection
            )
            #expect(presentation.questionVersion == 33)
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
                coverUpReactionAnswer(
                    choice: choiceIndex, identity: presentation.identity
                ),
            ])
        }
    }

    @Test("An older Cover Up prompt cannot submit after a newer snapshot")
    func staleCoverUpReactionFailsClosed() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try coverUpReactionEnvelope(loadGetGame())
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let staleIdentity = try #require(
            model.basicChoicePresentation(for: gameID)?.identity
        )

        let update = try snapshotUpdate(
            from: envelope,
            scenarioSteps: 34,
            replacingQuestionWith: coverUpQuestion(for: envelope)
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(update))))
        await connection.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.questionVersion == 34)
        #expect(current.identity != staleIdentity)
        #expect(
            await model.submitBasicChoice(staleIdentity, choiceIndex: 0) == .staleQuestion
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("A failed Cover Up reaction retries only on the current connection")
    func coverUpReactionRetryReconcilesConnectionIdentity() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try coverUpReactionEnvelope(loadGetGame())
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
            coverUpReactionAnswer(choice: 0, identity: oldIdentity),
        ])
        #expect(await replacement.sentData == [
            coverUpReactionAnswer(choice: 0, identity: current.identity),
        ])
    }

    private func coverUpReactionEnvelope(
        _ base: GetGameEnvelope
    ) throws -> GetGameEnvelope {
        let question = try coverUpQuestion(for: base)
        let withQuestion = try envelopeReplacingQuestion(
            base,
            scenarioSteps: 33,
            replacingQuestionWith: question
        )
        let raw = try ContractJSON.decode(
            JSONValue.self, from: ContractJSON.encode(withQuestion)
        )
        let withTreachery = try EnemyAttackFixtures.applying(
            operation: "add",
            path: [
                "game",
                "treacheries",
                Substring(CoverUpReactionFixtures.treacheryID.codingKey.stringValue),
            ],
            replacement: CoverUpReactionFixtures.treacheryValue(),
            to: raw
        )
        return try ContractJSON.decode(
            GetGameEnvelope.self, from: ContractJSON.encode(withTreachery)
        )
    }

    private func coverUpQuestion(
        for envelope: GetGameEnvelope
    ) throws -> JSONValue {
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        let locationID = try #require(
            projection.investigators.first(
                where: { $0.id == CoverUpReactionFixtures.investigatorID }
            )?.currentLocationID
        )
        return try CoverUpReactionFixtures.applying(
            replacement: .string(locationID.codingKey.stringValue),
            pointer: "/choices/0/windows/0/windowType/contents/1",
            to: CoverUpReactionFixtures.value()
        )
    }

    private func coverUpReactionAnswer(
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
