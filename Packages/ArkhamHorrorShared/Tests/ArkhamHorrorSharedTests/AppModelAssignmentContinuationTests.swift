@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    @Test(
        "Each assignment continuation claims source index zero once and sends version 7",
        arguments: AssignmentContinuationFixture.allCases
    )
    func assignmentContinuationDuplicatePendingAndAnswer(
        _ fixture: AssignmentContinuationFixture
    ) async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try assignmentContinuationEnvelope(fixture)
        let connection = FakeGameSocketConnection()
        await connection.setSendGated(true)
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(prompt.ownerID == envelope.playerID)
        #expect(prompt.questionVersion == DamageAssignmentFixtures.continuationQuestionVersion)
        #expect(prompt.question.supportedQuestion?.kind == .questionWithSource)
        #expect(prompt.choices.map(\.index) == [0])
        #expect(prompt.choices.map(\.title) == [fixture.title])
        #expect(prompt.canSubmit)

        let first = Task {
            await model.submitBasicChoice(prompt.identity, choiceIndex: 0)
        }
        await connection.waitUntilSendPending(1)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .sending)
        #expect(
            await model.submitBasicChoice(prompt.identity, choiceIndex: 0) == .alreadyPending
        )
        await connection.resumeOldestSend(with: .success(()))
        #expect(await first.value == .sentAwaitingSnapshot)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .awaitingSnapshot)
        #expect(try await connection.sentData == [
            DamageAssignmentFixtures.continuationAnswer(fixture),
        ])
    }

    @Test(
        "Same-version replacement revokes each continuation's retry authority",
        arguments: AssignmentContinuationFixture.allCases
    )
    func assignmentContinuationPromptReplacement(
        _ fixture: AssignmentContinuationFixture
    ) async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try assignmentContinuationEnvelope(fixture)
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: connection
        )
        let stale = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(stale, choiceIndex: 0) == .retryableFailure)

        let replacement = try damageAssignmentUpdate(
            from: envelope,
            scenarioSteps: DamageAssignmentFixtures.continuationQuestionVersion,
            rawQuestion: EncounterDeckDrawFixtures.value(),
            includeEnemy: true,
            includeInvestigator: true
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(replacement))))
        await connection.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.identity != stale)
        #expect(current.choices.map(\.title) == ["Draw encounter card"])
        #expect(current.actionPhase == nil)
        #expect(model.basicChoiceActions[gameID] == nil)
        #expect(await model.submitBasicChoice(stale, choiceIndex: 0) == .staleQuestion)
        #expect(await model.retryBasicChoice(stale) == .staleQuestion)
        #expect(try await connection.sentData == [
            DamageAssignmentFixtures.continuationAnswer(fixture),
        ])
    }

    @Test(
        "Removing either projected identity before either continuation fails closed",
        arguments: AssignmentContinuationFixture.allCases
    )
    func assignmentContinuationStaleIdentityBeforeSend(
        _ fixture: AssignmentContinuationFixture
    ) async throws {
        for missingIdentity in ["enemy", "investigator"] {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            let envelope = try assignmentContinuationEnvelope(fixture)
            let connection = FakeGameSocketConnection()
            let gameID = await startChoiceSession(
                model: model,
                fakes: fakes,
                envelope: envelope,
                connection: connection
            )
            let rendered = try #require(model.basicChoicePresentation(for: gameID))
            let update = try damageAssignmentUpdate(
                from: envelope,
                scenarioSteps: DamageAssignmentFixtures.continuationQuestionVersion,
                rawQuestion: DamageAssignmentFixtures.continuationValue(fixture),
                includeEnemy: missingIdentity != "enemy",
                includeInvestigator: missingIdentity != "investigator"
            )
            try await connection.enqueue(.event(.message(ContractJSON.encode(update))))
            await connection.waitUntilAwaitingNextEvent()

            let current = try #require(model.basicChoicePresentation(for: gameID))
            #expect(current.identity == rendered.identity)
            let choice = try #require(current.choices.first)
            let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
            #expect(!current.isChoiceActionable(choice, in: projection))
            #expect(
                await model.submitBasicChoice(
                    rendered.identity,
                    choiceIndex: 0
                ) == .unsupportedChoice
            )
            #expect(await connection.sentData.isEmpty)
        }
    }

    @Test(
        "Each continuation retries only after reconnect refreshes transport authority",
        arguments: AssignmentContinuationFixture.allCases
    )
    func assignmentContinuationRetryAndReconnect(
        _ fixture: AssignmentContinuationFixture
    ) async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try assignmentContinuationEnvelope(fixture)
        let first = FakeGameSocketConnection()
        await first.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: envelope,
            connection: first
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

        await fakes.service.resumeOldestGetGame(with: .success(envelope))
        await replacement.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.canRetry)
        #expect(current.actionChoiceIndex == 0)
        #expect(current.actionPhase == .retryable(.transportFailure))
        #expect(await model.retryBasicChoice(original) == .staleQuestion)
        await replacement.enqueueSendResult(.success(()))
        #expect(await model.retryBasicChoice(current.identity) == .sentAwaitingSnapshot)
        #expect(await model.submitBasicChoice(current.identity, choiceIndex: 0) == .alreadyPending)

        let expected = try DamageAssignmentFixtures.continuationAnswer(fixture)
        #expect(await first.sentData == [expected])
        #expect(await replacement.sentData == [expected])
    }

    private func assignmentContinuationEnvelope(
        _ fixture: AssignmentContinuationFixture
    ) throws -> GetGameEnvelope {
        try damageAssignmentEnvelope(
            rawQuestion: DamageAssignmentFixtures.continuationValue(fixture),
            scenarioSteps: DamageAssignmentFixtures.continuationQuestionVersion
        )
    }
}
