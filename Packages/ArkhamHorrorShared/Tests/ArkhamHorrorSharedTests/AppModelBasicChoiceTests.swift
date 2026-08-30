@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    func makeModern(_ model: AppModel) {
        model.sessionState = .signedIn(
            profile: .hosted, compatibility: .modern(capabilities: []), user: .sample
        )
    }

    func startChoiceSession(
        model: AppModel, fakes: Fakes, envelope: GetGameEnvelope,
        connection: FakeGameSocketConnection
    ) async -> GameID {
        let gameID = envelope.game.id
        await fakes.socketFactory.enqueueConnectResult(.success(connection))
        await fakes.service.enqueueGetGameResult(.success(envelope))
        _ = model.subscribeToLiveGame(gameID)
        await connection.waitUntilAwaitingNextEvent()
        return gameID
    }

    @Test("Participant identity comes only from REST and gates the exact question-map key")
    func participantIdentityGatesPrompt() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        let presentation = try #require(model.basicChoicePresentation(for: gameID))
        #expect(presentation.isAuthorized)
        #expect(presentation.ownerID == envelope.playerID)
        #expect(presentation.questionVersion == envelope.game.scenarioSteps)
        #expect(presentation.choices.count == 4)

        model.liveGameParticipantIdentities[gameID] = .participant(BoardTestFixtures.playerID())
        #expect(model.basicChoicePresentation(for: gameID) == nil)
        model.liveGameParticipantIdentities[gameID] = nil
        #expect(model.basicChoicePresentation(for: gameID) == nil)
    }

    @Test("Spectator and legacy sessions remain explicitly read-only")
    func spectatorAndLegacyRemainReadOnly() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        #expect(model.basicChoicePresentation(for: gameID)?.readOnlyReason == .legacyServer)

        model.liveGameParticipantIdentities[gameID] = .spectator
        #expect(model.basicChoicePresentation(for: gameID)?.readOnlyReason == .spectator)
    }

    @Test("Concurrent submissions claim globally and send the exact answer bytes once")
    func duplicateSubmissionSendsOnce() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.setSendGated(true)
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)

        let first = Task { await model.submitBasicChoice(identity, choiceIndex: 2) }
        await connection.waitUntilSendPending(1)
        let duplicate = await model.submitBasicChoice(identity, choiceIndex: 2)
        #expect(duplicate == .alreadyPending)
        await connection.resumeOldestSend(with: .success(()))
        #expect(await first.value == .sentAwaitingSnapshot)
        // Governed canonical bytes are intentionally kept as one exact token stream.
        // swiftlint:disable line_length
        #expect(await connection.sentData == [Data(
            #"{"contents":{"choice":2,"playerId":"00000000-0000-0000-0000-000000000001","questionVersion":3},"tag":"Answer"}"#.utf8
        )])
        // swiftlint:enable line_length
    }

    @Test("Transport failure restores an explicit manual retry and never reports success")
    func sendFailureIsRetryable() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.failure(GameSocketTransportError()))
        let envelope = try loadGetGame()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)

        #expect(await model.submitBasicChoice(identity, choiceIndex: 0) == .retryableFailure)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase
            == .retryable(.transportFailure))
    }

    @Test("An uncorrelated room GameError makes our outcome uncertain, never rejected")
    func gameErrorIsUncorrelated() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let envelope = try loadGetGame()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(identity, choiceIndex: 1) == .sentAwaitingSnapshot)

        await connection.enqueue(.event(.message(Data(
            #"{"tag":"GameError","contents":"token=https://secret.invalid"}"#.utf8
        ))))
        await connection.waitUntilAwaitingNextEvent()
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase
            == .retryable(.outcomeUncertain))
        #expect(model.basicChoicePresentation(for: gameID)?.serverFeedback
            == "The server reported a game error that could not be tied to your choice.")
        #expect(!(
            model.basicChoicePresentation(for: gameID)?.serverFeedback?.contains("secret")
                ?? true
        ))

        await connection.enqueueSendResult(.success(()))
        let currentIdentity = try #require(
            model.basicChoicePresentation(for: gameID)?.identity
        )
        #expect(await model.retryBasicChoice(currentIdentity) == .sentAwaitingSnapshot)
        #expect(await connection.sentData.count == 2)
    }

    @Test("A newer sequential question clears the resolved claim and is immediately actionable")
    func sequentialQuestionBecomesActionable() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let envelope = try loadGetGame()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(identity, choiceIndex: 0) == .sentAwaitingSnapshot)

        let newer = try snapshotUpdate(
            from: envelope, scenarioSteps: envelope.game.scenarioSteps + 1
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(newer))))
        await connection.waitUntilAwaitingNextEvent()
        let next = try #require(model.basicChoicePresentation(for: gameID))
        #expect(next.questionVersion == envelope.game.scenarioSteps + 1)
        #expect(next.canSubmit)
        #expect(next.actionPhase == nil)
        #expect(model.basicChoiceActions[gameID] == nil)
    }

    @Test("Authoritative socket snapshots apply undo and reset-to-zero step decreases")
    func lowerStepSnapshotsApply() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        let undo = try snapshotUpdate(from: envelope, scenarioSteps: 2)
        try await connection.enqueue(.event(.message(ContractJSON.encode(undo))))
        await connection.waitUntilAwaitingNextEvent()
        #expect(model.liveGameState(for: gameID).lastKnownProjection?.counters.scenarioSteps == 2)

        let newScenario = try snapshotUpdate(from: envelope, scenarioSteps: 0)
        try await connection.enqueue(.event(.message(ContractJSON.encode(newScenario))))
        await connection.waitUntilAwaitingNextEvent()
        #expect(model.liveGameState(for: gameID).lastKnownProjection?.counters.scenarioSteps == 0)
    }

    @Test("A lower-step authoritative snapshot resolves pending and enables its current prompt")
    func lowerStepSnapshotReconcilesPending() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let original = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(original, choiceIndex: 0) == .sentAwaitingSnapshot)

        let undo = try snapshotUpdate(from: envelope, scenarioSteps: 2)
        try await connection.enqueue(.event(.message(ContractJSON.encode(undo))))
        await connection.waitUntilAwaitingNextEvent()

        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.questionVersion == 2)
        #expect(current.actionPhase == nil)
        #expect(current.canSubmit)
        #expect(model.basicChoiceActions[gameID] == nil)
        await connection.enqueueSendResult(.success(()))
        #expect(
            await model.submitBasicChoice(current.identity, choiceIndex: 1)
                == .sentAwaitingSnapshot
        )
        #expect(await connection.sentData.count == 2)
    }

    @Test("A same-version replacement prompt discards the old claim and submits once")
    func changedRawPromptReplacesPending() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let original = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(original, choiceIndex: 0) == .sentAwaitingSnapshot)

        let replacement = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps,
            mutateRawQuestion: true
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(replacement))))
        await connection.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.identity.promptKey != original.promptKey)
        #expect(current.actionPhase == nil)

        await connection.enqueueSendResult(.success(()))
        #expect(
            await model.submitBasicChoice(current.identity, choiceIndex: 0)
                == .sentAwaitingSnapshot
        )
        #expect(await connection.sentData.count == 2)
    }

    @Test("Connection loss never resends; REST reconciliation requires a manual retry")
    func reconnectPendingRequiresManualRetry() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let firstConnection = FakeGameSocketConnection()
        await firstConnection.enqueueSendResult(.success(()))
        let envelope = try loadGetGame()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: firstConnection
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(identity, choiceIndex: 3) == .sentAwaitingSnapshot)

        let secondConnection = FakeGameSocketConnection()
        await fakes.socketFactory.enqueueConnectResult(.success(secondConnection))
        await fakes.service.enqueueGetGameResult(.success(envelope))
        await firstConnection.enqueue(.failure(GameSocketTransportError()))
        await secondConnection.waitUntilAwaitingNextEvent()

        #expect(await firstConnection.sentData.count == 1)
        #expect(await secondConnection.sentData.isEmpty)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase
            == .retryable(.outcomeUncertain))
    }

    @Test("Cancellation at the suspended send preserves an uncertain outcome")
    func cancellationDuringSendIsUncertain() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let connection = FakeGameSocketConnection()
        await connection.setSendGated(true)
        let envelope = try loadGetGame()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)

        let submission = Task { await model.submitBasicChoice(identity, choiceIndex: 0) }
        await connection.waitUntilSendPending(1)
        submission.cancel()
        await connection.resumeOldestSend(with: .success(()))

        #expect(await submission.value == .retryableFailure)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .uncertain)
        #expect(await connection.sentData.count == 1)
    }

    @Test("A stale scene identity cannot submit through a replacement session or socket")
    func replacementRejectsStaleIdentity() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let firstConnection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: firstConnection
        )
        let staleIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)

        model.stopLiveGameSession(gameID)
        await firstConnection.waitUntilClosed()
        let replacement = FakeGameSocketConnection()
        await fakes.socketFactory.enqueueConnectResult(.success(replacement))
        await fakes.service.enqueueGetGameResult(.success(envelope))
        _ = model.subscribeToLiveGame(gameID)
        await replacement.waitUntilAwaitingNextEvent()

        #expect(await model.submitBasicChoice(staleIdentity, choiceIndex: 0) == .staleQuestion)
        #expect(await replacement.sentData.isEmpty)
        #expect(model.basicChoicePresentation(for: gameID)?.identity != staleIdentity)
    }

    @Test("Last-viewer teardown retains uncertainty; authentication reset clears authority")
    func teardownAndAuthenticationReset() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let envelope = try loadGetGame()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(identity, choiceIndex: 0) == .sentAwaitingSnapshot)

        model.stopLiveGameSession(gameID)
        await connection.waitUntilClosed()
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .uncertain)

        model.resetLiveGameState()
        #expect(model.basicChoicePresentation(for: gameID) == nil)
        #expect(model.basicChoiceActions[gameID] == nil)
        #expect(model.liveGameParticipantIdentities[gameID] == nil)
    }

    func snapshotUpdate(
        from envelope: GetGameEnvelope,
        scenarioSteps: Int,
        mutateRawQuestion: Bool = false,
        questionTag: String? = nil
    ) throws -> BoardSnapshotUpdate {
        let data = try ContractJSON.encode(envelope.game)
        var value = try ContractJSON.decode(JSONValue.self, from: data)
        guard case var .object(object) = value else { throw TestFailure() }
        object["scenarioSteps"] = .number(.integer(Int64(scenarioSteps)))
        if mutateRawQuestion {
            guard case var .object(questions)? = object["question"] else {
                throw TestFailure()
            }
            let owner = try #require(questions.keys.first)
            guard case var .object(question)? = questions[owner] else { throw TestFailure() }
            guard case var .array(choices)? = question["choices"] else { throw TestFailure() }
            guard case var .object(firstChoice) = choices.first else { throw TestFailure() }
            guard case var .array(messages)? = firstChoice["messages"] else {
                throw TestFailure()
            }
            messages.append(.object(["tag": .string("FutureNestedMessage")]))
            firstChoice["messages"] = .array(messages)
            choices[0] = .object(firstChoice)
            question["choices"] = .array(choices)
            questions[owner] = .object(question)
            object["question"] = .object(questions)
        }
        if let questionTag {
            guard case var .object(questions)? = object["question"] else {
                throw TestFailure()
            }
            let owner = try #require(questions.keys.first)
            guard case var .object(question)? = questions[owner] else { throw TestFailure() }
            question["tag"] = .string(questionTag)
            questions[owner] = .object(question)
            object["question"] = .object(questions)
        }
        value = .object(object)
        let snapshot = try ContractJSON.decode(
            PublicGameSnapshot.self, from: ContractJSON.encode(value)
        )
        return .snapshot(snapshot)
    }
}
