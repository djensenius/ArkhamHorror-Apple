@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelLiveGameTests {
    private func makeModern(_ model: AppModel) {
        model.sessionState = .signedIn(
            profile: .hosted, compatibility: .modern(capabilities: []), user: .sample
        )
    }

    private func startChoiceSession(
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

    @Test("GameError releases the same authoritative prompt for explicit retry")
    func gameErrorRestoresPrompt() async throws {
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
            == .retryable(.serverRejected))
        #expect(model.basicChoicePresentation(for: gameID)?.statusMessage
            == "The server rejected this choice. Try again.")
    }

    @Test("A newer sequential question resolves accepted and is immediately actionable")
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
        #expect(next.actionPhase == .accepted)
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

    private func snapshotUpdate(
        from envelope: GetGameEnvelope, scenarioSteps: Int
    ) throws -> BoardSnapshotUpdate {
        let data = try ContractJSON.encode(envelope.game)
        var value = try ContractJSON.decode(JSONValue.self, from: data)
        guard case var .object(object) = value else { throw TestFailure() }
        object["scenarioSteps"] = .number(.integer(Int64(scenarioSteps)))
        value = .object(object)
        let snapshot = try ContractJSON.decode(
            PublicGameSnapshot.self, from: ContractJSON.encode(value)
        )
        return .snapshot(snapshot)
    }
}
