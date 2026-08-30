@testable import ArkhamHorrorShared
import Foundation
import Testing

/// AppModel-level coverage proving the Read/Location prompt slice (issue
/// djensenius/ArkhamHorror-Apple#35) reuses the exact same process-global answer
/// authority, prompt-identity/fingerprint, and reconciliation rules as every other
/// ``BasicChoiceQuestion`` kind -- no parallel authority, no special-cased resend/polling,
/// and no leaked accepted/pending state across a prompt-identity change.
extension AppModelLiveGameTests {
    /// Replaces the current answering player's raw question value wholesale with
    /// `rawQuestion` (a decoded Read/Location contract fixture), leaving every other
    /// snapshot field untouched except `scenarioSteps`. Mirrors
    /// `AppModelBasicChoiceTests.snapshotUpdate(...)`'s targeted-mutation style, but swaps
    /// the entire per-player question rather than mutating one field of the existing
    /// `ChooseOne` shape (Read's shape has no `choices` key at all).
    func snapshotUpdate(
        from envelope: GetGameEnvelope,
        scenarioSteps: Int,
        replacingQuestionWith rawQuestion: JSONValue
    ) throws -> BoardSnapshotUpdate {
        let data = try ContractJSON.encode(envelope.game)
        var value = try ContractJSON.decode(JSONValue.self, from: data)
        guard case var .object(object) = value else { throw TestFailure() }
        object["scenarioSteps"] = .number(.integer(Int64(scenarioSteps)))
        guard case var .object(questions)? = object["question"] else { throw TestFailure() }
        // Prefer the answering player's own map key (matching `Identifier`'s canonical
        // lowercase-hyphenated `codingKey`, see `BoardIdentifiers.swift`) so a fixture that
        // ever carries more than one `question` entry can't have the wrong player's
        // question mutated. Only a spectator envelope (`playerID == nil`) falls back to
        // `.first`, since there is then no answering player to key off of.
        let owner: String
        if let playerID = envelope.playerID {
            let expectedKey = playerID.rawValue.uuidString.lowercased()
            owner = try #require(
                questions.keys.first { $0 == expectedKey },
                "expected a question entry for answering player \(expectedKey)"
            )
        } else {
            owner = try #require(questions.keys.first)
        }
        questions[owner] = rawQuestion
        object["question"] = .object(questions)
        value = .object(object)
        let snapshot = try ContractJSON.decode(
            PublicGameSnapshot.self, from: ContractJSON.encode(value)
        )
        return .snapshot(snapshot)
    }

    func loadContractFixtureValue(_ name: String) throws -> JSONValue {
        try ContractJSON.decode(JSONValue.self, from: fixtureData(named: name))
    }

    /// Builds a REST `GetGameEnvelope` whose snapshot carries `rawQuestion` at
    /// `scenarioSteps`, otherwise identical to `base` -- used to simulate the socket-first
    /// REST reconnect fetch observing the exact same (still-pending) prompt identity a
    /// prior submission was sent against.
    func envelopeReplacingQuestion(
        _ base: GetGameEnvelope,
        scenarioSteps: Int,
        replacingQuestionWith rawQuestion: JSONValue
    ) throws -> GetGameEnvelope {
        let update = try snapshotUpdate(
            from: base, scenarioSteps: scenarioSteps, replacingQuestionWith: rawQuestion
        )
        guard case let .snapshot(snapshot) = update else { throw TestFailure() }
        return GetGameEnvelope(
            playerID: base.playerID,
            multiplayerMode: base.multiplayerMode,
            game: snapshot,
            eventID: base.eventID
        )
    }

    @Test("A Read continue prompt replaced immediately by a location prompt leaks no state")
    func readToLocationRapidTransition() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        let readQuestion = try loadContractFixtureValue("question-read")
        let readUpdate = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            replacingQuestionWith: readQuestion
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(readUpdate))))
        await connection.waitUntilAwaitingNextEvent()

        let storyPresentation = try #require(model.basicChoicePresentation(for: gameID))
        #expect(storyPresentation.questionVersion == envelope.game.scenarioSteps + 1)
        #expect(storyPresentation.canSubmit)
        #expect(storyPresentation.actionPhase == nil)
        let storyQuestion = try #require(storyPresentation.question.supportedQuestion)
        #expect(storyQuestion.kind == .read)
        #expect(storyQuestion.story?.readCards == nil)

        // The story-continue prompt "may arrive immediately" followed by a location
        // prompt at the very next scenario step -- no accepted/pending state may leak
        // from the never-submitted Read identity into this replacement.
        let locationQuestion = try loadContractFixtureValue("question-choose-one-location")
        let locationUpdate = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 2,
            replacingQuestionWith: locationQuestion
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(locationUpdate))))
        await connection.waitUntilAwaitingNextEvent()

        let locationPresentation = try #require(model.basicChoicePresentation(for: gameID))
        #expect(locationPresentation.questionVersion == envelope.game.scenarioSteps + 2)
        #expect(locationPresentation.canSubmit)
        #expect(locationPresentation.actionPhase == nil)
        #expect(model.basicChoiceActions[gameID] == nil)
        let locationBoardQuestion = try #require(
            locationPresentation.question.supportedQuestion
        )
        #expect(locationBoardQuestion.kind == .chooseOne)
        #expect(locationBoardQuestion.choices.first?.locationID != nil)

        // The stale Read identity can never answer the replacement location prompt.
        #expect(
            await model.submitBasicChoice(storyPresentation.identity, choiceIndex: 0)
                == .staleQuestion
        )
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Submitting the Read continue then receiving the location prompt clears pending")
    func submittedContinueThenLocationClearsPending() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.enqueueSendResult(.success(()))
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        let readQuestion = try loadContractFixtureValue("question-read-with-cards")
        let readUpdate = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            replacingQuestionWith: readQuestion
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(readUpdate))))
        await connection.waitUntilAwaitingNextEvent()
        let storyIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(
            await model.submitBasicChoice(storyIdentity, choiceIndex: 0) == .sentAwaitingSnapshot
        )

        let locationQuestion = try loadContractFixtureValue(
            "question-choose-one-location-multiple"
        )
        let locationUpdate = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 2,
            replacingQuestionWith: locationQuestion
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(locationUpdate))))
        await connection.waitUntilAwaitingNextEvent()

        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.questionVersion == envelope.game.scenarioSteps + 2)
        #expect(current.actionPhase == nil)
        #expect(current.canSubmit)
        #expect(model.basicChoiceActions[gameID] == nil)
        #expect(current.choices.map(\.index) == [0, 1, 2])

        await connection.enqueueSendResult(.success(()))
        #expect(
            await model.submitBasicChoice(current.identity, choiceIndex: 1)
                == .sentAwaitingSnapshot
        )
        #expect(await connection.sentData.count == 2)
    }

    @Test("Two concurrent submissions of the same Read continue claim globally and send once")
    func duplicateContinueSubmissionSendsOnce() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        await connection.setSendGated(true)
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )

        let readQuestion = try loadContractFixtureValue("question-read")
        let readUpdate = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            replacingQuestionWith: readQuestion
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(readUpdate))))
        await connection.waitUntilAwaitingNextEvent()
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)

        let first = Task { await model.submitBasicChoice(identity, choiceIndex: 0) }
        await connection.waitUntilSendPending(1)
        let duplicate = await model.submitBasicChoice(identity, choiceIndex: 0)
        #expect(duplicate == .alreadyPending)
        await connection.resumeOldestSend(with: .success(()))
        #expect(await first.value == .sentAwaitingSnapshot)
        #expect(await connection.sentData.count == 1)
    }

    @Test("Connection loss after a Read continue submission requires an explicit manual retry")
    func reconnectAfterContinueRequiresManualRetry() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let firstConnection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: firstConnection
        )
        let readQuestion = try loadContractFixtureValue("question-read")
        let readUpdate = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            replacingQuestionWith: readQuestion
        )
        try await firstConnection.enqueue(.event(.message(ContractJSON.encode(readUpdate))))
        await firstConnection.waitUntilAwaitingNextEvent()

        await firstConnection.enqueueSendResult(.success(()))
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(
            await model.submitBasicChoice(identity, choiceIndex: 0) == .sentAwaitingSnapshot
        )

        let secondConnection = FakeGameSocketConnection()
        await fakes.socketFactory.enqueueConnectResult(.success(secondConnection))
        let reconnectEnvelope = try envelopeReplacingQuestion(
            envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            replacingQuestionWith: readQuestion
        )
        await fakes.service.enqueueGetGameResult(.success(reconnectEnvelope))
        await firstConnection.enqueue(.failure(GameSocketTransportError()))
        await secondConnection.waitUntilAwaitingNextEvent()

        #expect(await firstConnection.sentData.count == 1)
        #expect(await secondConnection.sentData.isEmpty)
        #expect(
            model.basicChoicePresentation(for: gameID)?.actionPhase
                == .retryable(.outcomeUncertain)
        )
    }

    @Test("A lower-scenarioSteps snapshot resolves a pending Read continue and enables it")
    func undoResolvesPendingReadContinue() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let readQuestion = try loadContractFixtureValue("question-read")
        let readUpdate = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            replacingQuestionWith: readQuestion
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(readUpdate))))
        await connection.waitUntilAwaitingNextEvent()

        await connection.enqueueSendResult(.success(()))
        let readIdentity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(
            await model.submitBasicChoice(readIdentity, choiceIndex: 0) == .sentAwaitingSnapshot
        )

        // An authoritative "undo" snapshot lowers scenarioSteps back to the original
        // ChooseOne prompt -- it must resolve the pending Read claim and immediately
        // enable its own (lower-step) current prompt, never leaving the UI stuck pending
        // on a claim for a prompt that no longer exists.
        let undo = try snapshotUpdate(from: envelope, scenarioSteps: envelope.game.scenarioSteps)
        try await connection.enqueue(.event(.message(ContractJSON.encode(undo))))
        await connection.waitUntilAwaitingNextEvent()

        let current = try #require(model.basicChoicePresentation(for: gameID))
        #expect(current.questionVersion == envelope.game.scenarioSteps)
        #expect(current.actionPhase == nil)
        #expect(current.canSubmit)
        #expect(model.basicChoiceActions[gameID] == nil)
        #expect(current.question.supportedQuestion?.kind == .playerWindowChooseOne)
    }

    @Test("An uncorrelated GameError after a Read continue submission is uncertain, not rejected")
    func gameErrorAfterContinueIsUncorrelated() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        makeModern(model)
        let envelope = try loadGetGame()
        let connection = FakeGameSocketConnection()
        let gameID = await startChoiceSession(
            model: model, fakes: fakes, envelope: envelope, connection: connection
        )
        let readQuestion = try loadContractFixtureValue("question-read")
        let readUpdate = try snapshotUpdate(
            from: envelope,
            scenarioSteps: envelope.game.scenarioSteps + 1,
            replacingQuestionWith: readQuestion
        )
        try await connection.enqueue(.event(.message(ContractJSON.encode(readUpdate))))
        await connection.waitUntilAwaitingNextEvent()

        await connection.enqueueSendResult(.success(()))
        let identity = try #require(model.basicChoicePresentation(for: gameID)?.identity)
        #expect(await model.submitBasicChoice(identity, choiceIndex: 0) == .sentAwaitingSnapshot)

        await connection.enqueue(.event(.message(Data(
            #"{"tag":"GameError","contents":"unrelated room error"}"#.utf8
        ))))
        await connection.waitUntilAwaitingNextEvent()
        #expect(
            model.basicChoicePresentation(for: gameID)?.actionPhase
                == .retryable(.outcomeUncertain)
        )
    }
}
