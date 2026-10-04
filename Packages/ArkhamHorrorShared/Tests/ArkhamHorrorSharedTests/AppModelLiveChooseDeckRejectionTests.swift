// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

struct InstalledLiveChooseDeckPrompt {
    let attempt: LiveGameSessionAttempt
    let projection: BoardProjection
    let connectionID: UUID
    let connection: FakeGameSocketConnection
}

@MainActor
extension AppModelLiveChooseDeckTests {
    private struct DeckFixture: Decodable {
        let deck: Deck
    }

    func sampleRejectedDeck() throws -> Deck {
        let url = try #require(
            Bundle.module.url(
                forResource: "decks", withExtension: "json", subdirectory: "Fixtures/Contract"
            )
        )
        return try ContractJSON.decode(DeckFixture.self, from: Data(contentsOf: url)).deck
    }

    func makeSignedInRejectionModel() async -> AppModel {
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: ScriptedGameLifecycleService()
        )
        model.sessionState = .signedIn(
            profile: .hosted,
            compatibility: .modern(capabilities: []),
            user: .sample
        )
        return model
    }

    func sampleOwnerID() throws -> PlayerID {
        try PlayerID(#require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
    }

    private func chooseDeckProjection(
        ownerID: PlayerID,
        rawQuestion: JSONValue = .object(["tag": .string("ChooseDeck")])
    ) -> BoardProjection {
        var questions = UUIDKeyedMap<PlayerIDTag, BasicChoiceQuestionPayload>()
        questions[ownerID] = BasicChoiceQuestionPayload(
            rawValue: rawQuestion,
            state: .updateRequired(tag: "ChooseDeck")
        )
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        return BoardProjection(
            gameName: projection.gameName,
            hasCampaignContext: projection.hasCampaignContext,
            scenario: projection.scenario,
            campaignContinuation: projection.campaignContinuation,
            campaignSummary: projection.campaignSummary,
            acts: projection.acts,
            agendas: projection.agendas,
            locations: projection.locations,
            enemyLocations: projection.enemyLocations,
            investigators: projection.investigators,
            playerOrderCount: projection.playerOrderCount,
            enemyIDs: projection.enemyIDs,
            treacheryIDs: projection.treacheryIDs,
            treacheriesByID: projection.treacheriesByID,
            otherInvestigatorCount: projection.otherInvestigatorCount,
            killedInvestigatorCount: projection.killedInvestigatorCount,
            handCardsByPlayer: projection.handCardsByPlayer,
            orderedHandCardsByPlayer: projection.orderedHandCardsByPlayer,
            inPlayCardsByPlayer: projection.inPlayCardsByPlayer,
            threatTreacheriesByPlayer: projection.threatTreacheriesByPlayer,
            enemiesByLocationID: projection.enemiesByLocationID,
            engagedEnemiesByInvestigatorID: projection.engagedEnemiesByInvestigatorID,
            chaosBag: projection.chaosBag,
            counters: projection.counters,
            skillTest: projection.skillTest,
            questions: questions
        )
    }

    private func makeLiveChooseDeckAttempt(
        on model: AppModel,
        gameID: GameID
    ) -> LiveGameSessionAttempt {
        LiveGameSessionAttempt(
            gameID: gameID,
            profile: .hosted,
            attemptID: UUID(),
            sessionGeneration: model.generation,
            credentialEpoch: model.currentCredentialEpoch(for: ServerProfile.hosted.id),
            globalEpoch: model.currentGlobalCredentialEpoch()
        )
    }

    func installRejectedLivePrompt(
        on model: AppModel,
        gameID: GameID,
        ownerID: PlayerID,
        connection: FakeGameSocketConnection
    ) -> InstalledLiveChooseDeckPrompt {
        let projection = chooseDeckProjection(ownerID: ownerID)
        let attempt = makeLiveChooseDeckAttempt(on: model, gameID: gameID)
        let connectionID = UUID()
        model.liveGameParticipantIdentities[gameID] = .participant(ownerID)
        model.liveGameStates[gameID] = .live(projection)
        model.liveGameSessions[gameID] = LiveGameSessionHandle(
            attemptID: attempt.attemptID,
            task: Task {}
        )
        model.liveGameConnections[gameID] = LiveGameConnectionHandle(
            attemptID: attempt.attemptID,
            connectionID: connectionID,
            connection: connection
        )
        return InstalledLiveChooseDeckPrompt(
            attempt: attempt,
            projection: projection,
            connectionID: connectionID,
            connection: connection
        )
    }

    private func consumeLivePrompt(
        on model: AppModel,
        connection: FakeGameSocketConnection,
        installed: InstalledLiveChooseDeckPrompt
    ) -> Task<LiveGameSocketConsumeOutcome, Never> {
        Task {
            await model.consumeLiveGameSocket(
                installed.attempt,
                connection: connection,
                connectionID: installed.connectionID,
                projection: installed.projection
            )
        }
    }

    private func enqueueAnswerRejected(
        _ reason: String, on connection: FakeGameSocketConnection
    ) async {
        await connection.enqueue(.event(.message(Data(
            "{\"tag\":\"AnswerRejected\",\"reason\":\"\(reason)\",\"questionVersion\":null}".utf8
        ))))
        await connection.waitUntilAwaitingNextEvent()
    }

    private func expectLiveDeckAnswerable(
        _ model: AppModel, gameID: GameID, message: String
    ) {
        guard case .canAnswer = model.canAnswerLiveChooseDeck(for: gameID) else {
            Issue.record("\(message)")
            return
        }
    }

    private func expectDeckRejectionReason(
        _ reason: String, model: AppModel, gameID: GameID, promptKey: BasicChoicePromptKey
    ) {
        #expect(model.liveChooseDeckRejectionReason(for: gameID, promptKey: promptKey) == reason)
    }

    @Test("AnswerRejected releases a live deck answer and surfaces the server reason")
    // swiftlint:disable:next function_body_length
    func answerRejectedReleasesLiveDeckAnswer() async throws {
        let model = await makeSignedInRejectionModel()
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let deck = try sampleRejectedDeck()
        let installed = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection
        )
        let promptKey = try #require(model.canAnswerLiveChooseDeck(for: gameID).promptKey)
        let consume = consumeLivePrompt(on: model, connection: connection, installed: installed)
        await connection.waitUntilAwaitingNextEvent()
        await connection.enqueueSendResult(.success(()))

        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))
        #expect(model.liveChooseDeckRejectionReason(for: gameID, promptKey: promptKey) == nil)
        #expect(model.liveChooseDeckIsAwaitingAnswer(for: gameID, promptKey: promptKey))

        await enqueueAnswerRejected("Deck already claimed", on: connection)

        expectDeckRejectionReason(
            "Deck already claimed", model: model, gameID: gameID, promptKey: promptKey
        )
        #expect(model.basicChoiceActions[gameID] == nil)
        #expect(!model.liveChooseDeckIsAwaitingAnswer(for: gameID, promptKey: promptKey))
        expectLiveDeckAnswerable(
            model,
            gameID: gameID,
            message: "A rejected DeckAnswer should leave the ChooseDeck prompt answerable"
        )

        await connection.enqueueSendResult(.failure(GameSocketTransportError()))
        #expect(await !model.chooseDeckForLivePrompt(deck, in: gameID))
        #expect(model.liveChooseDeckRejectionReason(for: gameID, promptKey: promptKey) == nil)
        #expect(model.basicChoiceActions[gameID]?.phase == .retryable(.transportFailure))
        #expect(!model.liveChooseDeckIsAwaitingAnswer(for: gameID, promptKey: promptKey))
        expectLiveDeckAnswerable(
            model,
            gameID: gameID,
            message: "A failed retry should leave the ChooseDeck prompt answerable"
        )

        await enqueueAnswerRejected("Delayed deck reason", on: connection)
        expectDeckRejectionReason(
            "Delayed deck reason", model: model, gameID: gameID, promptKey: promptKey
        )
        #expect(model.basicChoiceActions[gameID] == nil)
        #expect(!model.liveChooseDeckIsAwaitingAnswer(for: gameID, promptKey: promptKey))
        expectLiveDeckAnswerable(
            model,
            gameID: gameID,
            message: "A delayed rejected DeckAnswer should leave the prompt answerable"
        )

        await connection.enqueueSendResult(.success(()))
        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))
        #expect(await connection.sentData.count == 3)
        consume.cancel()
    }

    @Test("GameError is not treated as a correlated live deck rejection")
    func gameErrorDoesNotReleaseLiveDeckAnswerAsRejected() async throws {
        let model = await makeSignedInRejectionModel()
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let deck = try sampleRejectedDeck()
        let installed = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection
        )
        let promptKey = try #require(model.canAnswerLiveChooseDeck(for: gameID).promptKey)
        let consume = consumeLivePrompt(on: model, connection: connection, installed: installed)
        await connection.waitUntilAwaitingNextEvent()
        await connection.enqueueSendResult(.success(()))

        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))
        await connection.enqueue(.event(.message(Data(
            #"{"tag":"GameError","contents":"room-wide error"}"#.utf8
        ))))
        await connection.waitUntilAwaitingNextEvent()

        #expect(model.liveChooseDeckRejectionReason(for: gameID, promptKey: promptKey) == nil)
        #expect(model.basicChoiceActions[gameID]?.phase == .retryable(.outcomeUncertain))
        #expect(!model.liveChooseDeckIsAwaitingAnswer(for: gameID, promptKey: promptKey))
        #expect(model.liveChooseDeckServerFeedback(
            for: gameID,
            promptKey: promptKey
        ) == "The server reported a game error that could not be tied to your choice.")

        await connection.enqueueSendResult(.success(()))
        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))
        #expect(await connection.sentData.count == 2)
        #expect(model.basicChoiceActions[gameID]?.phase == .awaitingSnapshot)
        consume.cancel()
    }

    @Test("Rejection while deck send is suspended permits an immediate replacement")
    func rejectionWhileDeckSendSuspendedEnablesReplacement() async throws {
        let model = await makeSignedInRejectionModel()
        let connection = FakeGameSocketConnection()
        await connection.setSendGated(true)
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let deck = try sampleRejectedDeck()
        let installed = installRejectedLivePrompt(
            on: model, gameID: gameID, ownerID: ownerID, connection: connection
        )
        let promptKey = try #require(model.canAnswerLiveChooseDeck(for: gameID).promptKey)
        let consume = consumeLivePrompt(on: model, connection: connection, installed: installed)
        await connection.waitUntilAwaitingNextEvent()

        let first = Task { await model.chooseDeckForLivePrompt(deck, in: gameID) }
        await connection.waitUntilSendPending(1)
        #expect(!model.liveChooseDeckPickerEnabled(
            for: gameID,
            promptKey: promptKey,
            validation: .valid
        ))
        let rejection = Data(
            #"{"tag":"AnswerRejected","reason":"Suspended send rejected","questionVersion":null}"#
                .utf8
        )
        await connection.enqueue(.event(.message(rejection)))
        await connection.waitUntilAwaitingNextEvent()
        #expect(model.liveChooseDeckRejectionReason(
            for: gameID,
            promptKey: promptKey
        ) == "Suspended send rejected")
        #expect(!model.liveChooseDeckIsAwaitingAnswer(for: gameID, promptKey: promptKey))
        #expect(model.liveChooseDeckPickerEnabled(
            for: gameID,
            promptKey: promptKey,
            validation: .valid
        ))

        let second = Task { await model.chooseDeckForLivePrompt(deck, in: gameID) }
        await connection.waitUntilSendPending(2)
        await connection.resumeOldestSend(with: .success(()))
        #expect(await first.value)
        #expect(model.basicChoiceActions[gameID]?.phase == .sending)
        await connection.resumeOldestSend(with: .success(()))
        #expect(await second.value)
        #expect(model.basicChoiceActions[gameID]?.phase == .awaitingSnapshot)
        consume.cancel()
    }

    @Test("Late success for an old retryable deck attempt cannot advance its replacement")
    func lateOldDeckSendSuccessCannotAdvanceReplacement() async throws {
        let model = await makeSignedInRejectionModel()
        let connection = FakeGameSocketConnection()
        await connection.setSendGated(true)
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let deck = try sampleRejectedDeck()
        let installed = installRejectedLivePrompt(
            on: model, gameID: gameID, ownerID: ownerID, connection: connection
        )
        let promptKey = try #require(model.canAnswerLiveChooseDeck(for: gameID).promptKey)
        let consume = consumeLivePrompt(on: model, connection: connection, installed: installed)
        await connection.waitUntilAwaitingNextEvent()

        let first = Task { await model.chooseDeckForLivePrompt(deck, in: gameID) }
        await connection.waitUntilSendPending(1)
        await connection.enqueue(.event(.message(Data(
            #"{"tag":"GameError","contents":"room-wide error"}"#.utf8
        ))))
        await connection.waitUntilAwaitingNextEvent()
        #expect(model.basicChoiceActions[gameID]?.phase == .retryable(.outcomeUncertain))
        #expect(!model.liveChooseDeckIsAwaitingAnswer(for: gameID, promptKey: promptKey))

        let second = Task { await model.chooseDeckForLivePrompt(deck, in: gameID) }
        await connection.waitUntilSendPending(2)
        await connection.resumeOldestSend(with: .success(()))
        #expect(await !first.value)
        #expect(model.basicChoiceActions[gameID]?.phase == .sending)

        await connection.resumeOldestSend(with: .failure(GameSocketTransportError()))
        #expect(await !second.value)
        #expect(model.basicChoiceActions[gameID]?.phase == .retryable(.transportFailure))
        #expect(!model.liveChooseDeckIsAwaitingAnswer(for: gameID, promptKey: promptKey))
        #expect(await connection.sentData.count == 2)
        consume.cancel()
    }

    @Test("Reconnect retryable live deck answer can send and ignores old rejection")
    func reconnectRetryableDeckAnswerCanSend() async throws {
        let model = await makeSignedInRejectionModel()
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let deck = try sampleRejectedDeck()
        let installed = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection
        )
        let promptKey = try #require(model.canAnswerLiveChooseDeck(for: gameID).promptKey)
        await connection.enqueueSendResult(.success(()))
        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))

        model.markBasicChoiceOutcomeUncertain(gameID: gameID, connectionID: installed.connectionID)
        let reconnected = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: FakeGameSocketConnection()
        )
        model.reconcileBasicChoice(
            gameID: gameID,
            projection: reconnected.projection,
            isRESTSnapshot: true
        )
        #expect(model.basicChoiceActions[gameID]?.phase == .retryable(.outcomeUncertain))
        #expect(!model.liveChooseDeckIsAwaitingAnswer(for: gameID, promptKey: promptKey))

        await reconnected.connection.enqueueSendResult(.success(()))
        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))
        #expect(await reconnected.connection.sentData.count == 1)

        let oldRejection = Data(
            #"{"tag":"AnswerRejected","reason":"old rejection","questionVersion":null}"#.utf8
        )
        let oldUpdate = try ContractJSON.decode(BoardSnapshotUpdate.self, from: oldRejection)
        guard case let .answerRejected(rejection) = oldUpdate else {
            Issue.record("Expected exact old rejection bytes to decode")
            return
        }
        model.handleBasicChoiceAnswerRejected(
            gameID: gameID,
            sessionAttemptID: installed.attempt.attemptID,
            connectionID: installed.connectionID,
            rejection: rejection
        )
        #expect(model.basicChoiceActions[gameID]?.phase == .awaitingSnapshot)
        #expect(model.liveChooseDeckRejectionReason(for: gameID, promptKey: promptKey) == nil)
    }
}
