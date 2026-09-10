@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Focused AppModel coverage for the three authoritative investigation controls added by
/// issue #42: they must reuse the existing prompt identity, duplicate-claim fencing,
/// retry, and stale-prompt rejection machinery without inventing a parallel answer path.
extension AppModelLiveGameTests {
    @Test("Two scenes racing Skip Triggers claim its exact source index only once")
    func skipTriggersDuplicateSubmissionSendsExactSourceIndexOnce() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let baseEnvelope = try loadGetGame()
        let question = try skipTriggersQuestion()
        let envelope = try envelopeReplacingQuestion(
            baseEnvelope,
            scenarioSteps: baseEnvelope.game.scenarioSteps,
            replacingQuestionWith: question
        )
        let connection = FakeGameSocketConnection()
        await connection.setSendGated(true)
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let presentation = try #require(model.basicChoicePresentation(for: gameID))
        #expect(presentation.choices.map(\.index) == [0, 1, 2, 3])
        #expect(presentation.choices.map(\.isSupported) == [true, false, true, true])

        let first = Task {
            await model.submitBasicChoice(presentation.identity, choiceIndex: 2)
        }
        await connection.waitUntilSendPending(1)
        #expect(
            await model.submitBasicChoice(presentation.identity, choiceIndex: 2)
                == .alreadyPending
        )
        await connection.resumeOldestSend(with: .success(()))
        #expect(await first.value == .sentAwaitingSnapshot)
        #expect(await connection.sentData == [
            expectedAnswer(for: presentation.identity, choiceIndex: 2),
        ])
    }

    @Test("Start Skill Test retries after transport failure and reconnects on the current socket")
    func startSkillTestReconnectRetrySendsExactSourceIndexOnce() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let baseEnvelope = try loadGetGame()
        let question = try startSkillTestQuestion()
        let envelope = try envelopeReplacingQuestion(
            baseEnvelope,
            scenarioSteps: baseEnvelope.game.scenarioSteps,
            replacingQuestionWith: question
        )
        let firstConnection = FakeGameSocketConnection()
        await firstConnection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: firstConnection
        )
        let oldIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(
            await model.submitBasicChoice(oldIdentity, choiceIndex: 3) == .retryableFailure
        )
        #expect(
            model.basicChoicePresentation(for: gameID)?.actionPhase
                == .retryable(.transportFailure)
        )

        let replacement = try await reconnectChoiceSession(
            fakes: fakes,
            oldConnection: firstConnection,
            envelope: envelope
        )
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.identity != oldIdentity)
        #expect(current.actionPhase == .retryable(.transportFailure))
        #expect(current.canRetry)
        #expect(await replacement.sentData.isEmpty)

        await replacement.enqueueSendResult(.success(()))
        #expect(await model.retryBasicChoice(current.identity) == .sentAwaitingSnapshot)
        #expect(await firstConnection.sentData == [
            expectedAnswer(for: oldIdentity, choiceIndex: 3),
        ])
        #expect(await replacement.sentData == [
            expectedAnswer(for: current.identity, choiceIndex: 3),
        ])
    }

    @Test("Apply Results sends its exact source index and rejects a stale prompt identity")
    func applyResultsSubmissionRejectsStaleIdentityAfterPromptAdvance() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let baseEnvelope = try loadGetGame()
        let question = try applySkillTestResultsQuestion()
        let envelope = try envelopeReplacingQuestion(
            baseEnvelope,
            scenarioSteps: baseEnvelope.game.scenarioSteps,
            replacingQuestionWith: question
        )
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let staleIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(
            await model.submitBasicChoice(staleIdentity, choiceIndex: 2)
                == .sentAwaitingSnapshot
        )
        #expect(await connection.sentData == [
            expectedAnswer(for: staleIdentity, choiceIndex: 2),
        ])

        let advancedPrompt = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            replacingQuestionWith: question
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(advancedPrompt))))
        await connection.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.questionVersion == envelope.game.scenarioSteps + 1)
        #expect(current.identity != staleIdentity)
        #expect(current.actionPhase == nil)
        #expect(current.canSubmit)
        #expect(await model.submitBasicChoice(staleIdentity, choiceIndex: 2) == .staleQuestion)
        #expect(await connection.sentData.count == 1)
    }

    private func skipTriggersQuestion() throws -> JSONValue {
        try basicChoiceQuestion(
            tag: "WindowChooseOne",
            choices: [
                endTurnChoice,
                #"{"tag":"SkipTriggersButton","investigatorId":"c01001","messages":[]}"#,
                #"{"tag":"SkipTriggersButton","investigatorId":"c01001"}"#,
                endTurnChoice,
            ]
        )
    }

    private func startSkillTestQuestion() throws -> JSONValue {
        try basicChoiceQuestion(
            tag: "ChooseOne",
            choices: [
                endTurnChoice,
                #"{"tag":"StartSkillTestButton","investigatorId":"c01001","messages":[]}"#,
                endTurnChoice,
                #"{"tag":"StartSkillTestButton","investigatorId":"c01001"}"#,
            ]
        )
    }

    private func applySkillTestResultsQuestion() throws -> JSONValue {
        try basicChoiceQuestion(
            tag: "ChooseOne",
            choices: [
                endTurnChoice,
                #"{"tag":"SkillTestApplyResultsButton","messages":[]}"#,
                #"{"tag":"SkillTestApplyResultsButton"}"#,
            ]
        )
    }

    private func basicChoiceQuestion(
        tag: String, choices: [String]
    ) throws -> JSONValue {
        try ContractJSON.decode(
            JSONValue.self,
            from: Data(#"{"tag":"\#(tag)","choices":[\#(choices.joined(separator: ","))]}"#.utf8)
        )
    }

    private var endTurnChoice: String {
        """
        {"tag":"EndTurnButton","investigatorId":"c01001",\
        "messages":[{"tag":"InvestigatorMessage","contents":{}}]}
        """
    }

    private func expectedAnswer(
        for identity: BasicChoicePromptIdentity, choiceIndex: Int
    ) -> Data {
        Data(
            """
            {"contents":{"choice":\(choiceIndex),\
            "playerId":"\(identity.ownerID.rawValue.uuidString.lowercased())",\
            "questionVersion":\(identity.questionVersion)},"tag":"Answer"}
            """.utf8
        )
    }

    private func reconnectChoiceSession(
        fakes: Fakes,
        oldConnection: FakeGameSocketConnection,
        envelope: GetGameEnvelope
    ) async throws -> FakeGameSocketConnection {
        let replacement = FakeGameSocketConnection()
        await fakes.socketFactory.enqueueConnectResult(.success(replacement))
        await fakes.service.enqueueGetGameResult(.success(envelope))
        await oldConnection.enqueue(.failure(GameSocketTransportError()))
        await replacement.waitUntilAwaitingNextEvent()
        return replacement
    }
}
