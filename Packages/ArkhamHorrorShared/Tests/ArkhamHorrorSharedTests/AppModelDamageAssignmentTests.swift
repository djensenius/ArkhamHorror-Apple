@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    @Test("Both assignment source indices claim once and send their published answers")
    func damageAssignmentDuplicatePendingAndAnswers() async throws {
        for (choiceIndex, fixture) in [
            (0, "answer-enemy-attack-assign-damage"),
            (1, "answer-enemy-attack-assign-horror"),
        ] {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            let envelope = try damageAssignmentEnvelope()
            let connection = FakeGameSocketConnection()
            await connection.setSendGated(true)
            let gameID = await startChoiceSession(
                model: model, fakes: fakes, envelope: envelope, connection: connection
            )
            let prompt = try #require(model.basicChoicePresentation(for: gameID))
            #expect(prompt.ownerID == BoardTestFixtures.playerID("000000000001"))
            #expect(prompt.questionVersion == 6)
            #expect(prompt.question.supportedQuestion?.kind == .questionWithSource)
            #expect(prompt.choices.map(\.index) == [0, 1])
            #expect(prompt.choices.map(\.title) == ["Assign 1 damage", "Assign 1 horror"])
            #expect(prompt.canSubmit)

            let first = Task {
                await model.submitBasicChoice(prompt.identity, choiceIndex: choiceIndex)
            }
            await connection.waitUntilSendPending(1)
            #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .sending)
            #expect(
                await model.submitBasicChoice(prompt.identity, choiceIndex: choiceIndex)
                    == .alreadyPending
            )
            #expect(
                await model.submitBasicChoice(
                    prompt.identity,
                    choiceIndex: choiceIndex == 0 ? 1 : 0
                ) == .alreadyPending
            )
            await connection.resumeOldestSend(with: .success(()))
            #expect(await first.value == .sentAwaitingSnapshot)
            #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .awaitingSnapshot)
            #expect(try await connection.sentData == [damageAssignmentAnswer(fixture)])
        }
    }

    @Test("Same-version prompt replacement revokes assignment retry authority")
    func damageAssignmentPromptReplacement() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try damageAssignmentEnvelope()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let stale = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(stale, choiceIndex: 1) == .retryableFailure)

        let replacement = try damageAssignmentUpdate(
            from: envelope,
            scenarioSteps: 6,
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
        #expect(await model.submitBasicChoice(stale, choiceIndex: 1) == .staleQuestion)
        #expect(await model.retryBasicChoice(stale) == .staleQuestion)
        #expect(
            try await connection.sentData
                == [damageAssignmentAnswer("answer-enemy-attack-assign-horror")]
        )
    }

    @Test("Identity removal immediately before either assignment choice fails closed")
    func damageAssignmentStaleIdentityBeforeSend() async throws {
        for missingIdentity in ["enemy", "investigator"] {
            for choiceIndex in [0, 1] {
                let (model, fakes) = makeSignedInModel()
                await model.flowTask?.value
                makeModern(model)
                let envelope = try damageAssignmentEnvelope()
                let connection = FakeGameSocketConnection()
                let gameID = await startChoiceSession(
                    model: model, fakes: fakes, envelope: envelope, connection: connection
                )
                let rendered = try #require(model.basicChoicePresentation(for: gameID))
                let update = try damageAssignmentUpdate(
                    from: envelope,
                    scenarioSteps: 6,
                    includeEnemy: missingIdentity != "enemy",
                    includeInvestigator: missingIdentity != "investigator"
                )
                try await connection.enqueue(.event(.message(ContractJSON.encode(update))))
                await connection.waitUntilAwaitingNextEvent()

                let current = try #require(model.basicChoicePresentation(for: gameID))
                #expect(current.identity == rendered.identity)
                let choice = current.choices[choiceIndex]
                let projection = try #require(model.liveGameStates[gameID]?.lastKnownProjection)
                #expect(!current.isChoiceActionable(choice, in: projection))
                #expect(
                    await model.submitBasicChoice(
                        rendered.identity, choiceIndex: choiceIndex
                    ) == .unsupportedChoice
                )
                #expect(await connection.sentData.isEmpty)
            }
        }
    }

    @Test("Horror-first assignment retries manually after refreshed reconnect authority")
    func damageAssignmentRetryAndReconnect() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try damageAssignmentEnvelope()
        let first = FakeGameSocketConnection()
        await first.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: first
        )
        let original = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(original, choiceIndex: 1) == .retryableFailure)
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
        #expect(current.actionChoiceIndex == 1)
        #expect(current.actionPhase == .retryable(.transportFailure))
        #expect(await model.retryBasicChoice(original) == .staleQuestion)
        await replacement.enqueueSendResult(.success(()))
        #expect(await model.retryBasicChoice(current.identity) == .sentAwaitingSnapshot)
        #expect(await model.submitBasicChoice(current.identity, choiceIndex: 0) == .alreadyPending)
        let expected = try damageAssignmentAnswer("answer-enemy-attack-assign-horror")
        #expect(await first.sentData == [expected])
        #expect(await replacement.sentData == [expected])
    }

    @Test("Uncorrelated GameError keeps damage-first assignment outcome uncertain")
    func damageAssignmentGameErrorIsUncertain() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try damageAssignmentEnvelope()
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        await connection.enqueueSendResult(.success(()))
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(identity, choiceIndex: 0) == .sentAwaitingSnapshot)

        await connection.enqueue(.event(.message(Data(
            #"{"tag":"GameError","contents":"unrelated room error"}"#.utf8
        ))))
        await connection.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.actionPhase == .retryable(.outcomeUncertain))
        #expect(current.canRetry)
        #expect(current.actionChoiceIndex == 0)
        #expect(
            current.serverFeedback
                == "The server reported a game error that could not be tied to your choice."
        )
        #expect(
            try await connection.sentData
                == [damageAssignmentAnswer("answer-enemy-attack-assign-damage")]
        )
    }

    private func damageAssignmentEnvelope() throws -> GetGameEnvelope {
        let base = try loadGetGame()
        let update = try damageAssignmentUpdate(
            from: base, scenarioSteps: 6, includeEnemy: true, includeInvestigator: true
        )
        guard case let .snapshot(snapshot) = update else { throw TestFailure() }
        return GetGameEnvelope(
            playerID: base.playerID,
            multiplayerMode: base.multiplayerMode,
            game: snapshot,
            eventID: base.eventID
        )
    }

    private func damageAssignmentUpdate(
        from envelope: GetGameEnvelope,
        scenarioSteps: Int,
        rawQuestion: JSONValue? = nil,
        includeEnemy: Bool,
        includeInvestigator: Bool
    ) throws -> BoardSnapshotUpdate {
        var value = try ContractJSON.decode(
            JSONValue.self, from: ContractJSON.encode(envelope.game)
        )
        guard case var .object(object) = value else { throw TestFailure() }
        object["scenarioSteps"] = .number(.integer(Int64(scenarioSteps)))

        guard case var .object(questions)? = object["question"],
              let playerID = envelope.playerID
        else { throw TestFailure() }
        questions[playerID.codingKey.stringValue] =
            try rawQuestion ?? DamageAssignmentFixtures.value()
        object["question"] = .object(questions)

        guard case var .object(enemies)? = object["enemies"] else { throw TestFailure() }
        let enemy = DamageAssignmentFixtures.enemyID.codingKey.stringValue
        if includeEnemy {
            enemies[enemy] = .null
        } else {
            enemies.removeValue(forKey: enemy)
        }
        object["enemies"] = .object(enemies)

        guard case var .object(investigators)? = object["investigators"] else {
            throw TestFailure()
        }
        let investigator = DamageAssignmentFixtures.investigatorID.codingKey.stringValue
        if !includeInvestigator {
            investigators.removeValue(forKey: investigator)
        }
        object["investigators"] = .object(investigators)

        value = .object(object)
        let snapshot = try ContractJSON.decode(
            PublicGameSnapshot.self, from: ContractJSON.encode(value)
        )
        return .snapshot(snapshot)
    }

    private func damageAssignmentAnswer(_ fixture: String) throws -> Data {
        let published = try ContractJSON.decode(
            BasicChoiceAnswer.self,
            from: DamageAssignmentFixtures.data(fixture)
        )
        return try ContractJSON.encode(published)
    }
}
