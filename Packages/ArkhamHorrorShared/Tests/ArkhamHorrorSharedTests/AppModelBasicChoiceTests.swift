// swiftlint:disable file_length
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

    private func getGameEnvelopeWithAdditionalQuestion(
        for playerID: PlayerID
    ) throws -> GetGameEnvelope {
        let originalKey = "00000000-0000-0000-0000-000000000001"
        let otherKey = playerID.rawValue.uuidString.lowercased()
        guard case var .object(root) = try LosslessJSONParser.parse(
            fixtureData(named: "get-game")
        ),
            case var .object(game) = root["game"],
            case var .object(questions) = game["question"],
            case var .object(presentations) = game["questionPresentation"],
            let question = questions[originalKey],
            let presentation = presentations[originalKey]
        else { throw TestFailure() }

        questions[otherKey] = question
        presentations[otherKey] = presentation
        game["question"] = .object(questions)
        game["questionPresentation"] = .object(presentations)
        root["game"] = .object(game)
        return try ContractJSON.decode(
            GetGameEnvelope.self,
            from: LosslessJSONSerializer.serialize(.object(root))
        )
    }

    private func liveStandaloneEnvelope(
        promptNamed name: String,
        scenarioID: String
    ) throws -> GetGameEnvelope {
        let fixture = try liveStandaloneFixture(named: name)
        guard case var .object(root) = try LosslessJSONParser.parse(fixtureData(named: "get-game")),
              case let .string(playerKey)? = root["playerId"],
              case var .object(game)? = root["game"],
              case var .object(questions)? = game["question"],
              case var .object(presentations)? = game["questionPresentation"]
        else { throw TestFailure() }

        questions[playerKey] = fixture.rawQuestion
        presentations[playerKey] = try ContractJSON.decode(
            JSONValue.self,
            from: ContractJSON.encode(fixture.questionPresentation)
        )
        game["question"] = .object(questions)
        game["questionPresentation"] = .object(presentations)
        game["scenarioSteps"] = .number(.integer(Int64(fixture.questionVersion)))
        if case var .object(mode)? = game["mode"],
           case var .object(scenario)? = mode["That"] {
            scenario["id"] = .string(scenarioID)
            scenario["reference"] = .string(scenarioID)
            mode["That"] = .object(scenario)
            game["mode"] = .object(mode)
        }
        root["game"] = .object(game)
        return try ContractJSON.decode(
            GetGameEnvelope.self,
            from: LosslessJSONSerializer.serialize(.object(root))
        )
    }

    private func liveStandaloneFixture(named name: String) throws -> LiveStandalonePromptFixture {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/LiveStandaloneSettingsPrompt"
        ))
        return try ContractJSON.decode(
            LiveStandalonePromptFixture.self,
            from: Data(contentsOf: url)
        )
    }

    private static func identity(
        from identity: BasicChoicePromptIdentity,
        questionVersion: Int
    ) -> BasicChoicePromptIdentity {
        BasicChoicePromptIdentity(
            gameID: identity.gameID,
            ownerID: identity.ownerID,
            questionVersion: questionVersion,
            rawQuestion: identity.rawQuestion,
            questionPresentation: identity.questionPresentation,
            sessionAttemptID: identity.sessionAttemptID,
            connectionID: identity.connectionID
        )
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

    @Test("Participants use only their own entry when several server prompts are pending")
    func participantsUseOwnPendingQuestionOnly() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let otherID = BoardTestFixtures.playerID("000000000002")
        let thirdID = BoardTestFixtures.playerID("000000000003")
        let envelope = try getGameEnvelopeWithAdditionalQuestion(for: otherID)
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        let ownerPrompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(ownerPrompt.ownerID == envelope.playerID)
        #expect(ownerPrompt.readOnlyReason == nil)

        model.liveGameParticipantIdentities[gameID] = .participant(otherID)
        let otherPrompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(otherPrompt.ownerID == otherID)
        #expect(otherPrompt.readOnlyReason == nil)

        model.liveGameParticipantIdentities[gameID] = .participant(thirdID)
        #expect(model.basicChoicePresentation(for: gameID) == nil)
        #expect(
            await model.submitBasicChoice(ownerPrompt.identity, choiceIndex: 0) == .staleQuestion
        )

        model.liveGameParticipantIdentities[gameID] = .spectator
        #expect(model.basicChoicePresentation(for: gameID) == nil)
        #expect(
            await model.submitBasicChoice(ownerPrompt.identity, choiceIndex: 0) == .staleQuestion
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Legacy participants are read-only, while spectators see no prompt contents")
    func legacyParticipantReadOnlyAndSpectatorPromptHidden() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let legacyPrompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(legacyPrompt.readOnlyReason == .legacyServer)

        model.liveGameParticipantIdentities[gameID] = .spectator
        #expect(model.basicChoicePresentation(for: gameID) == nil)
        #expect(
            await model.submitBasicChoice(legacyPrompt.identity, choiceIndex: 0) == .staleQuestion
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Standalone settings answer rejects stale versions and wrong owners without sending")
    func standaloneSettingsRejectsStaleAndWrongOwnerWithoutSending() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try liveStandaloneEnvelope(
            promptNamed: "pick-scenario-settings",
            scenarioID: "c86001"
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let staleIdentity = Self.identity(
            from: prompt.identity,
            questionVersion: prompt.identity.questionVersion + 1
        )

        #expect(
            await model.submitStandaloneSettingsAnswer(staleIdentity, contents: [])
                == .staleQuestion
        )
        model.liveGameParticipantIdentities[gameID] = .participant(
            BoardTestFixtures.playerID("000000000002")
        )
        #expect(
            await model.submitStandaloneSettingsAnswer(prompt.identity, contents: [])
                == .staleQuestion
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Midnight Masks standalone settings are unsupported and send nothing")
    func standaloneSettingsUnsupportedScenarioSendsNothing() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try liveStandaloneEnvelope(
            promptNamed: "pick-scenario-settings",
            scenarioID: "c01120"
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))

        #expect(
            await model.submitStandaloneSettingsAnswer(prompt.identity, contents: [])
                == .unsupportedChoice
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Scenario-specific answer rejects stale versions and wrong owners without sending")
    func scenarioSpecificRejectsStaleAndWrongOwnerWithoutSending() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try liveStandaloneEnvelope(
            promptNamed: "pick-scenario-specific-laid-to-rest",
            scenarioID: "c90054"
        )
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let spiritDeck = try #require(prompt.laidToRestSpiritDeckPrompt)
        let contents = try #require(spiritDeck.answer(
            selectedCodes: Array(spiritDeck.rawStringEntryCodes.prefix(spiritDeck.count))
        ))
        let staleIdentity = Self.identity(
            from: prompt.identity,
            questionVersion: prompt.identity.questionVersion + 1
        )

        #expect(
            await model.submitScenarioSpecificAnswer(staleIdentity, contents: contents)
                == .staleQuestion
        )
        model.liveGameParticipantIdentities[gameID] = .spectator
        #expect(
            await model.submitScenarioSpecificAnswer(prompt.identity, contents: contents)
                == .staleQuestion
        )
        #expect(await connection.sentData.isEmpty)
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

        try await connection.enqueue(.event(.message(ContractJSON.encode(
            BoardSnapshotUpdate.snapshot(envelope.game)
        ))))
        await connection.waitUntilAwaitingNextEvent()
        #expect(model.basicChoicePresentation(for: gameID)?.serverFeedback == nil)

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
}

private struct LiveStandalonePromptFixture: Decodable {
    let questionVersion: Int
    let rawQuestion: JSONValue
    let questionPresentation: QuestionPresentation
}
