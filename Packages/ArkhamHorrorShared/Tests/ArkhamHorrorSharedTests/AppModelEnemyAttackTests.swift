@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    @Test("Enemy attack claims source index zero once and sends the published answer")
    func enemyAttackDuplicatePendingAndAnswer() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try enemyAttackEnvelope()
        let connection = FakeGameSocketConnection()
        await connection.setSendGated(true)
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(prompt.ownerID == BoardTestFixtures.playerID("000000000001"))
        #expect(prompt.questionVersion == 5)
        #expect(prompt.question.supportedQuestion?.kind == .chooseOneAtATime)
        #expect(prompt.choices.map(\.index) == [0])
        #expect(prompt.choices.map(\.title) == ["Resolve enemy attack"])
        #expect(prompt.canSubmit)

        let first = Task { await model.submitBasicChoice(prompt.identity, choiceIndex: 0) }
        await connection.waitUntilSendPending(1)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .sending)
        #expect(await model.submitBasicChoice(prompt.identity, choiceIndex: 0) == .alreadyPending)
        await connection.resumeOldestSend(with: .success(()))
        #expect(await first.value == .sentAwaitingSnapshot)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .awaitingSnapshot)
        #expect(try await connection.sentData == [enemyAttackAnswer()])

        let advanced = try enemyAttackUpdate(
            from: envelope, scenarioSteps: 6, includeEnemy: true, includeInvestigator: true
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(advanced))))
        await connection.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.questionVersion == 6)
        #expect(current.actionPhase == nil)
        #expect(current.canSubmit)
        #expect(await model.submitBasicChoice(prompt.identity, choiceIndex: 0) == .staleQuestion)
        #expect(try await connection.sentData == [enemyAttackAnswer()])
    }

    @Test("Same-version prompt replacement revokes enemy attack retry authority")
    func enemyAttackPromptReplacement() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try enemyAttackEnvelope()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let stale = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(stale, choiceIndex: 0) == .retryableFailure)

        let replacement = try enemyAttackUpdate(
            from: envelope,
            scenarioSteps: 5,
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
        #expect(try await connection.sentData == [enemyAttackAnswer()])
    }

    @Test("Enemy or investigator removal immediately before send fails current projection checks")
    func enemyAttackStaleIdentityBeforeSend() async throws {
        for missingIdentity in ["enemy", "investigator"] {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            makeModern(model)
            let envelope = try enemyAttackEnvelope()
            let connection = FakeGameSocketConnection()
            let gameID = await startChoiceSession(
                model: model, fakes: fakes, envelope: envelope, connection: connection
            )
            let rendered = try #require(model.basicChoicePresentation(for: gameID))
            let update = try enemyAttackUpdate(
                from: envelope,
                scenarioSteps: 5,
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
                await model.submitBasicChoice(rendered.identity, choiceIndex: 0)
                    == .unsupportedChoice
            )
            #expect(await connection.sentData.isEmpty)
        }
    }

    @Test("Enemy attack retries manually after reconnect and refreshed REST authority")
    func enemyAttackRetryAndReconnect() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try enemyAttackEnvelope()
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
        #expect(try await first.sentData == [enemyAttackAnswer()])
        #expect(try await replacement.sentData == [enemyAttackAnswer()])
    }

    @Test("Uncorrelated GameError keeps enemy attack outcome uncertain")
    func enemyAttackGameErrorIsUncertain() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try enemyAttackEnvelope()
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
        #expect(
            current.serverFeedback
                == "The server reported a game error that could not be tied to your choice."
        )
        #expect(try await connection.sentData == [enemyAttackAnswer()])
    }

    private func enemyAttackEnvelope() throws -> GetGameEnvelope {
        let base = try loadGetGame()
        let update = try enemyAttackUpdate(
            from: base, scenarioSteps: 5, includeEnemy: true, includeInvestigator: true
        )
        guard case let .snapshot(snapshot) = update else { throw TestFailure() }
        return GetGameEnvelope(
            playerID: base.playerID,
            multiplayerMode: base.multiplayerMode,
            game: snapshot,
            eventID: base.eventID
        )
    }

    private func enemyAttackUpdate(
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
        let owner = playerID.codingKey.stringValue
        questions[owner] = try rawQuestion ?? EnemyAttackFixtures.value()
        object["question"] = .object(questions)

        guard case var .object(enemies)? = object["enemies"] else { throw TestFailure() }
        let enemy = EnemyAttackFixtures.enemyID.codingKey.stringValue
        if includeEnemy {
            enemies[enemy] = .null
        } else {
            enemies.removeValue(forKey: enemy)
        }
        object["enemies"] = .object(enemies)

        guard case var .object(investigators)? = object["investigators"] else {
            throw TestFailure()
        }
        let investigator = EnemyAttackFixtures.investigatorID.codingKey.stringValue
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

    private func enemyAttackAnswer() throws -> Data {
        let published = try ContractJSON.decode(
            BasicChoiceAnswer.self,
            from: EnemyAttackFixtures.data("answer-enemy-attack")
        )
        return try ContractJSON.encode(published)
    }
}
