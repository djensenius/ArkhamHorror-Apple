@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    @Test("A resolved answer cannot suppress the next update-required prompt")
    func resolvedAnswerDoesNotSuppressUpdateRequiredReason() async throws {
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

        let unsupported = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            questionTag: "FutureChoiceQuestion"
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(unsupported))))
        await connection.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.actionPhase == nil)
        #expect(current.readOnlyReason == .updateRequired)
        #expect(current.statusMessage == "This prompt requires a newer app version.")
        #expect(model.basicChoiceActions[gameID] == nil)
    }

    @Test("A transport failure refreshes across reconnect and retries on the current socket once")
    func transportFailureRefreshesAcrossReconnect() async throws {
        try await assertRetryablePhaseRefreshesAcrossReconnect(.transportFailure)
    }

    @Test("A correlated server rejection can refresh across reconnect on a future contract")
    func serverRejectionRefreshesAcrossReconnect() async throws {
        try await assertRetryablePhaseRefreshesAcrossReconnect(.serverRejected)
    }

    @Test("A replacement socket cannot retry until its socket-first REST snapshot arrives")
    func reconnectWaitsForRESTBeforeRetry() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let firstConnection = FakeGameSocketConnection()
        await firstConnection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: firstConnection
        )
        let oldIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(
            await model.submitBasicChoice(oldIdentity, choiceIndex: 1) == .retryableFailure
        )

        await fakes.service.setGetGameGated(true)
        let replacement = FakeGameSocketConnection()
        await fakes.socketFactory.enqueueConnectResult(.success(replacement))
        await firstConnection.enqueue(.failure(GameSocketTransportError()))
        await fakes.service.waitUntilGetGamePending(1)

        let beforeREST = try #require(model.basicChoicePresentation(for: gameID))
        #expect(beforeREST.identity != oldIdentity)
        #expect(beforeREST.actionPhase == .uncertain)
        #expect(!beforeREST.canRetry)
        #expect(await model.retryBasicChoice(beforeREST.identity) == .staleQuestion)
        #expect(await replacement.sentData.isEmpty)

        await fakes.service.resumeOldestGetGame(with: .success(envelope))
        await replacement.waitUntilAwaitingNextEvent()
        let afterREST = try #require(model.basicChoicePresentation(for: gameID))
        #expect(afterREST.actionPhase == .retryable(.transportFailure))
        #expect(afterREST.canRetry)
    }

    @Test("REST participant replacement clears old authority and enables the new owner's prompt")
    func participantReplacementClearsOldAuthority() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let originalEnvelope = try loadGetGame()
        let firstConnection = FakeGameSocketConnection()
        await firstConnection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: originalEnvelope,
            connection: firstConnection
        )
        let oldIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(
            await model.submitBasicChoice(oldIdentity, choiceIndex: 0) == .retryableFailure
        )

        let newPlayer = BoardTestFixtures.playerID("000000000802")
        let replacementEnvelope = try envelope(
            originalEnvelope, participant: newPlayer, moveQuestionToParticipant: true
        )
        let replacement = try await reconnect(
            fakes: fakes,
            oldConnection: firstConnection,
            envelope: replacementEnvelope
        )
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.ownerID == newPlayer)
        #expect(current.actionPhase == nil)
        #expect(current.canSubmit)
        #expect(model.basicChoiceActions[gameID] == nil)

        await replacement.enqueueSendResult(.success(()))
        #expect(
            await model.submitBasicChoice(current.identity, choiceIndex: 0)
                == .sentAwaitingSnapshot
        )
        #expect(await replacement.sentData.count == 1)
    }

    @Test("REST spectator replacement clears participant answer authority")
    func spectatorReplacementClearsAuthority() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let originalEnvelope = try loadGetGame()
        let firstConnection = FakeGameSocketConnection()
        await firstConnection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model,
            fakes: fakes,
            envelope: originalEnvelope,
            connection: firstConnection
        )
        let oldIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(
            await model.submitBasicChoice(oldIdentity, choiceIndex: 0) == .retryableFailure
        )

        let spectatorEnvelope = try envelope(
            originalEnvelope, participant: nil, moveQuestionToParticipant: false
        )
        let replacement = try await reconnect(
            fakes: fakes,
            oldConnection: firstConnection,
            envelope: spectatorEnvelope
        )
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.readOnlyReason == .spectator)
        #expect(current.actionPhase == nil)
        #expect(!current.canSubmit)
        #expect(model.basicChoiceActions[gameID] == nil)
        #expect(
            await model.submitBasicChoice(current.identity, choiceIndex: 0) == .readOnly
        )
        #expect(await replacement.sentData.isEmpty)
    }

    @Test("A stale connection's GameError cannot mutate a replacement pending answer")
    func staleGameErrorCannotMutateReplacementPending() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let firstConnection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: firstConnection
        )
        model.stopLiveGameSession(gameID)
        await firstConnection.waitUntilClosed()

        let replacement = FakeGameSocketConnection()
        await replacement.enqueueSendResult(.success(()))
        await fakes.socketFactory.enqueueConnectResult(.success(replacement))
        await fakes.service.enqueueGetGameResult(.success(envelope))
        _ = model.subscribeToLiveGame(gameID)
        await replacement.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(
            await model.submitBasicChoice(current, choiceIndex: 0) == .sentAwaitingSnapshot
        )

        await firstConnection.enqueue(.event(.message(Data(
            #"{"tag":"GameError","contents":"another player's error"}"#.utf8
        ))))
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .awaitingSnapshot)
        #expect(model.basicChoicePresentation(for: gameID)?.serverFeedback == nil)
        #expect(await replacement.sentData.count == 1)
    }

    @Test("A stale suspended send completion cannot mutate its replacement prompt's claim")
    func staleSendCompletionCannotMutateReplacement() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.setSendGated(true)
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let oldIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        let oldSubmission = Task {
            await model.submitBasicChoice(oldIdentity, choiceIndex: 0)
        }
        await connection.waitUntilSendPending(1)

        let replacementUpdate = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps,
            mutateRawQuestion: true
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(replacementUpdate))))
        await connection.waitUntilAwaitingNextEvent()
        let current = try #require(model.basicChoicePresentation(for: gameID))
        let currentSubmission = Task {
            await model.submitBasicChoice(current.identity, choiceIndex: 1)
        }
        await connection.waitUntilSendPending(2)

        await connection.resumeOldestSend(with: .success(()))
        #expect(await oldSubmission.value == .retryableFailure)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .sending)
        await connection.resumeOldestSend(with: .success(()))
        #expect(await currentSubmission.value == .sentAwaitingSnapshot)
        #expect(model.basicChoicePresentation(for: gameID)?.actionPhase == .awaitingSnapshot)
        #expect(await connection.sentData.count == 2)
    }

    private func assertRetryablePhaseRefreshesAcrossReconnect(
        _ reason: BasicChoiceRetryReason
    ) async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let firstConnection = FakeGameSocketConnection()
        await firstConnection.enqueueSendResult(.failure(GameSocketTransportError()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: firstConnection
        )
        let oldIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(
            await model.submitBasicChoice(oldIdentity, choiceIndex: 1) == .retryableFailure
        )
        model.basicChoiceActions[gameID]?.phase = .retryable(reason)

        let replacement = try await reconnect(
            fakes: fakes,
            oldConnection: firstConnection,
            envelope: envelope
        )
        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.identity != oldIdentity)
        #expect(current.actionPhase == .retryable(reason))
        #expect(current.canRetry)

        await replacement.enqueueSendResult(.success(()))
        #expect(
            await model.retryBasicChoice(current.identity) == .sentAwaitingSnapshot
        )
        #expect(await firstConnection.sentData.count == 1)
        #expect(await replacement.sentData.count == 1)
    }

    private func reconnect(
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

    private func envelope(
        _ envelope: GetGameEnvelope,
        participant: PlayerID?,
        moveQuestionToParticipant: Bool
    ) throws -> GetGameEnvelope {
        var value = try ContractJSON.decode(
            JSONValue.self, from: ContractJSON.encode(envelope)
        )
        guard case var .object(root) = value,
              case var .object(game)? = root["game"]
        else { throw TestFailure() }
        root["playerId"] = participant.map {
            .string($0.rawValue.uuidString.lowercased())
        } ?? .null
        if moveQuestionToParticipant {
            let participant = try #require(participant)
            guard case let .object(questions)? = game["question"] else {
                throw TestFailure()
            }
            let question = try #require(questions.values.first)
            game["question"] = .object([
                participant.rawValue.uuidString.lowercased(): question,
            ])
        }
        root["game"] = .object(game)
        value = .object(root)
        return try ContractJSON.decode(
            GetGameEnvelope.self, from: ContractJSON.encode(value)
        )
    }
}
