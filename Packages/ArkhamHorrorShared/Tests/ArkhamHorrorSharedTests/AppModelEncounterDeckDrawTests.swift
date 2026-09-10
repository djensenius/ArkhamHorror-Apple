@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    @Test("Encounter draw claims index zero once and waits for an authoritative snapshot")
    func encounterDrawDuplicateAndPending() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try encounterDrawEnvelope()
        let connection = FakeGameSocketConnection()
        await connection.setSendGated(true)
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(prompt.choices.map(\.index) == [0])
        #expect(prompt.choices.map(\.title) == ["Draw encounter card"])
        #expect(prompt.canSubmit)
        let first = Task { await model.submitBasicChoice(prompt.identity, choiceIndex: 0) }
        await connection.waitUntilSendPending(1)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .sending)
        #expect(model.basicChoicePresentation(for: gameID)?.actionChoiceIndex == 0)
        #expect(await model.submitBasicChoice(prompt.identity, choiceIndex: 0) == .alreadyPending)
        await connection.resumeOldestSend(with: .success(()))
        #expect(await first.value == .sentAwaitingSnapshot)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .awaitingSnapshot)
        #expect(model.basicChoicePresentation(for: gameID)?.canSubmit == false)
        #expect(await connection.sentData == [encounterDrawAnswer])

        let advanced = try snapshotUpdate(
            from: envelope, scenarioSteps: 4,
            replacingQuestionWith: EncounterDeckDrawFixtures.value()
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(advanced))))
        await connection.waitUntilAwaitingNextEvent()
        let next = try #require(model.basicChoicePresentation(for: gameID))
        #expect(next.questionVersion == 4)
        #expect(next.canSubmit)
        #expect(next.actionPhase == nil)
        #expect(await model.submitBasicChoice(prompt.identity, choiceIndex: 0) == .staleQuestion)
        #expect(await connection.sentData == [encounterDrawAnswer])
    }

    @Test("Encounter draw retries manually after reconnect and only after current REST authority")
    func encounterDrawRetryAndReconnect() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try encounterDrawEnvelope()
        let first = FakeGameSocketConnection()
        await first.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: first
        )
        let original = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(original, choiceIndex: 0) == .retryableFailure)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase
            == .retryable(.transportFailure))

        await fakes.service.setGetGameGated(true)
        let replacement = FakeGameSocketConnection()
        await fakes.socketFactory.enqueueConnectResult(.success(replacement))
        await first.enqueue(.failure(GameSocketTransportError()))
        await fakes.service.waitUntilGetGamePending(1)
        let waiting = try #require(model.basicChoicePresentation(for: gameID))
        #expect(waiting.identity != original)
        #expect(!waiting.canRetry)
        #expect(await model.retryBasicChoice(waiting.identity) == .staleQuestion)
        #expect(await replacement.sentData.isEmpty)

        await fakes.service.resumeOldestGetGame(with: .success(envelope))
        await replacement.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.canRetry)
        #expect(current.actionChoiceIndex == 0)
        #expect(current.actionPhase == .retryable(.transportFailure))
        #expect(await model.retryBasicChoice(original) == .staleQuestion)
        #expect(await replacement.sentData.isEmpty)
        await replacement.enqueueSendResult(.success(()))
        #expect(await model.retryBasicChoice(current.identity) == .sentAwaitingSnapshot)
        #expect(await model.submitBasicChoice(current.identity, choiceIndex: 0) == .alreadyPending)
        #expect(await first.sentData == [encounterDrawAnswer])
        #expect(await replacement.sentData == [encounterDrawAnswer])
    }

    @Test("Same-version malformed draw replacement revokes stale submission and retry authority")
    func encounterDrawMalformedReplacement() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try encounterDrawEnvelope()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let stale = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(stale, choiceIndex: 0) == .retryableFailure)
        let unknown = try EncounterDeckDrawFixtures.replacing(
            EncounterDeckDrawFixtures.value(),
            at: "/choices/0/messages/0/contents/1/cardDrawDeck/tag".split(separator: "/"),
            with: .string("FutureDeck")
        )
        let update = try snapshotUpdate(
            from: envelope, scenarioSteps: 3, replacingQuestionWith: unknown
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(update))))
        await connection.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.identity != stale)
        #expect(current.choices.map(\.index) == [0])
        #expect(current.choices.map(\.isSupported) == [false])
        #expect(current.choices[0].title == "Update required")
        #expect(current.actionPhase == nil)
        #expect(!current.canRetry)
        #expect(model.basicChoiceActions[gameID] == nil)
        #expect(await model.submitBasicChoice(stale, choiceIndex: 0) == .staleQuestion)
        #expect(await model.retryBasicChoice(stale) == .staleQuestion)
        #expect(
            await model.submitBasicChoice(current.identity, choiceIndex: 0) == .unsupportedChoice
        )
        #expect(await connection.sentData == [encounterDrawAnswer])
    }

    private func encounterDrawEnvelope() throws -> GetGameEnvelope {
        try envelopeReplacingQuestion(
            loadGetGame(), scenarioSteps: 3,
            replacingQuestionWith: EncounterDeckDrawFixtures.value()
        )
    }

    private var encounterDrawAnswer: Data {
        Data(
            """
            {"contents":{"choice":0,"playerId":"00000000-0000-0000-0000-000000000001",\
            "questionVersion":3},"tag":"Answer"}
            """.utf8
        )
    }
}
