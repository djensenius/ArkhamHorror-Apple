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

    private func replacementScenarioSummary(
        from projection: BoardProjection,
        id: String,
        isSideStory: Bool = true
    ) -> BoardScenarioSummary {
        let scenario = projection.scenario
        return BoardScenarioSummary(
            id: id,
            displayName: scenario?.displayName ?? id,
            subtitle: scenario?.subtitle,
            difficulty: scenario?.difficulty ?? .easy,
            turn: scenario?.turn ?? 0,
            reference: scenario?.reference ?? id,
            usesGrid: scenario?.usesGrid ?? false,
            isPrelude: scenario?.isPrelude ?? false,
            isSideStory: isSideStory,
            inResolution: scenario?.inResolution ?? false,
            started: scenario?.started ?? false
        )
    }

    private func chooseDeckProjection(
        ownerID: PlayerID,
        rawQuestion: JSONValue = .object(["tag": .string("ChooseDeck")]),
        scenarioID: String? = nil,
        isSideStory: Bool = true
    ) -> BoardProjection {
        var questions = UUIDKeyedMap<PlayerIDTag, BasicChoiceQuestionPayload>()
        questions[ownerID] = BasicChoiceQuestionPayload(
            rawValue: rawQuestion,
            state: .updateRequired(tag: "ChooseDeck")
        )
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        let scenario = scenarioID.map {
            replacementScenarioSummary(from: projection, id: $0, isSideStory: isSideStory)
        } ?? projection.scenario
        return BoardProjection(
            gameName: projection.gameName,
            hasCampaignContext: projection.hasCampaignContext,
            campaignI18nScope: projection.campaignI18nScope,
            scenario: scenario,
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
        connection: FakeGameSocketConnection,
        scenarioID: String? = nil,
        isSideStory: Bool = true
    ) -> InstalledLiveChooseDeckPrompt {
        let projection = chooseDeckProjection(
            ownerID: ownerID,
            scenarioID: scenarioID,
            isSideStory: isSideStory
        )
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

    @Test("Catalog side-story investigator requirement blocks the wrong live deck")
    func catalogSideStoryRequirementBlocksWrongInvestigatorDeck() async throws {
        let catalog = try loadLiveCampaignCatalog()
        let model = await makeCatalogBackedRejectionModel(catalog: catalog)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let wrongDeck = try sampleRejectedDeck()
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c90020"
        )
        let promptKey = try #require(model.canAnswerLiveChooseDeck(for: gameID).promptKey)

        await model.refreshLiveChooseDeckRestriction(for: gameID)

        #expect(model.liveChooseDeckRestrictionDeckError(
            for: wrongDeck,
            in: gameID
        ) == "This scenario requires Agnes Baker")
        #expect(!model.liveChooseDeckPickerEnabled(
            for: gameID,
            promptKey: promptKey,
            validation: .valid,
            deck: wrongDeck
        ))
        #expect(await !model.chooseDeckForLivePrompt(wrongDeck, in: gameID))
        #expect(await connection.sentData.isEmpty)

        await connection.enqueueSendResult(.success(()))
        let agnesDeck = try rewrittenDeck(
            wrongDeck,
            investigatorCode: "c01004",
            investigatorName: "Agnes Baker"
        )
        #expect(model.liveChooseDeckRestrictionDeckError(for: agnesDeck, in: gameID) == nil)
        #expect(await model.chooseDeckForLivePrompt(agnesDeck, in: gameID))
        #expect(await connection.sentData.count == 1)
    }

    @Test("Required-investigator matching normalizes c-prefixed alternate fronts")
    func requiredInvestigatorMatchingNormalizesAlternateFrontCodes() async throws {
        let catalog = try loadLiveCampaignCatalog()
        let model = await makeCatalogBackedRejectionModel(catalog: catalog)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let daisyParallelDeck = try sampleRejectedDeck()
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c90004"
        )

        await model.refreshLiveChooseDeckRestriction(for: gameID)

        #expect(model.liveChooseDeckRestrictionDeckError(
            for: daisyParallelDeck,
            in: gameID
        ) == nil)
        await connection.enqueueSendResult(.success(()))
        #expect(await model.chooseDeckForLivePrompt(daisyParallelDeck, in: gameID))
        #expect(await connection.sentData.count == 1)
    }

    @Test("Unavailable campaign catalog leaves live deck choice to the player")
    func unavailableCatalogLeavesDeckChoiceToPlayer() async throws {
        let service = LiveChooseDeckCampaignCatalogService(result: .failure(TestFailure()))
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: ScriptedGameLifecycleService(),
            campaignCatalogService: service
        )
        model.sessionState = .signedIn(
            profile: .hosted,
            compatibility: .modern(
                capabilities: [CampaignCatalogAdvertisement.capabilityIdentifier],
                campaignCatalog: advertisement(revision: "1.unavailable")
            ),
            user: .sample
        )
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let deck = try sampleRejectedDeck()
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c90020"
        )

        await model.refreshLiveChooseDeckRestriction(for: gameID)

        let unavailableFallback = "Side-story investigator requirements cannot be checked "
            + "right now. Make sure this deck uses the scenario's required investigator."
        #expect(model.liveChooseDeckRestrictionNotice(for: gameID) == liveChooseDeckLocalized(
            "liveChooseDeck.restriction.unavailable",
            unavailableFallback
        ))
        await connection.enqueueSendResult(.success(()))
        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))
        #expect(await connection.sentData.count == 1)
    }

    @Test("Alternate-front matching ignores other non-string metadata values")
    func alternateFrontMatchingIgnoresOtherMetadataValues() async throws {
        let catalog = try loadLiveCampaignCatalog()
        let model = await makeCatalogBackedRejectionModel(catalog: catalog)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let deck = try rewrittenDeck(
            sampleRejectedDeck(),
            investigatorCode: "c01001",
            investigatorName: "Roland Banks",
            meta: #"{"alternate_front":"c90017","arkhamdb":null,"version":1}"#
        )
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c90020"
        )

        await model.refreshLiveChooseDeckRestriction(for: gameID)

        #expect(model.liveChooseDeckRestrictionDeckError(for: deck, in: gameID) == nil)
        await connection.enqueueSendResult(.success(()))
        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))
        #expect(await connection.sentData.count == 1)
    }

    @Test("Empty alternate-front metadata falls back to the deck investigator")
    func emptyAlternateFrontFallsBackToDeckInvestigator() async throws {
        let catalog = try loadLiveCampaignCatalog()
        let model = await makeCatalogBackedRejectionModel(catalog: catalog)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let deck = try rewrittenDeck(
            sampleRejectedDeck(),
            investigatorCode: "c01004",
            investigatorName: "Agnes Baker",
            meta: #"{"alternate_front":""}"#
        )
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c90020"
        )

        await model.refreshLiveChooseDeckRestriction(for: gameID)

        #expect(model.liveChooseDeckRestrictionDeckError(for: deck, in: gameID) == nil)
        await connection.enqueueSendResult(.success(()))
        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))
        #expect(await connection.sentData.count == 1)
    }

    @Test("Loading live deck restriction blocks sending")
    func loadingRestrictionBlocksSending() async throws {
        let model = await makeSignedInRejectionModel()
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let deck = try sampleRejectedDeck()
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c90020"
        )
        let promptKey = try #require(model.canAnswerLiveChooseDeck(for: gameID).promptKey)
        model.liveChooseDeckRestrictionChecks[gameID] = .loading

        #expect(!model.liveChooseDeckPickerEnabled(
            for: gameID,
            promptKey: promptKey,
            validation: .valid,
            deck: deck
        ))
        #expect(await !model.chooseDeckForLivePrompt(deck, in: gameID))
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Non-side-story deck prompts skip the side-story restriction check")
    func nonSideStoryDeckPromptSkipsRestrictionCheck() async throws {
        let service = try CountingCatalogService(
            document: loadLiveCampaignCatalog()
        )
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: ScriptedGameLifecycleService(),
            campaignCatalogService: service
        )
        model.sessionState = .signedIn(
            profile: .hosted,
            compatibility: .modern(
                capabilities: [CampaignCatalogAdvertisement.capabilityIdentifier],
                campaignCatalog: advertisement(revision: "1.non-side-story")
            ),
            user: .sample
        )
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c01101",
            isSideStory: false
        )

        await model.refreshLiveChooseDeckRestriction(for: gameID)

        #expect(model.liveChooseDeckRestrictionNotice(for: gameID) == nil)
        #expect(await service.loadCount() == 0)
    }

    @Test("Side stories without required investigators do not show restriction notices")
    func sideStoryWithoutRequiredInvestigatorHasNoRestrictionNotice() async throws {
        let catalog = try loadLiveCampaignCatalog()
        let model = await makeCatalogBackedRejectionModel(catalog: catalog)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let deck = try sampleRejectedDeck()
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c81001"
        )

        await model.refreshLiveChooseDeckRestriction(for: gameID)

        #expect(model.liveChooseDeckRestrictionNotice(for: gameID) == nil)
        #expect(model.liveChooseDeckRestrictionDeckError(for: deck, in: gameID) == nil)
    }

    @Test("Unknown side-story scenario ids fail open without notices after catalog lookup")
    func unknownSideStoryScenarioFailsOpenAfterCatalogLookup() async throws {
        let catalog = try loadLiveCampaignCatalog()
        let model = await makeCatalogBackedRejectionModel(catalog: catalog)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let deck = try sampleRejectedDeck()
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c99999"
        )

        await model.refreshLiveChooseDeckRestriction(for: gameID)

        #expect(model.liveChooseDeckRestrictionNotice(for: gameID) == nil)
        #expect(model.liveChooseDeckRestrictionDeckError(for: deck, in: gameID) == nil)
    }

    @Test("Missing catalog capability only shows unavailable copy for possible side stories")
    func missingCatalogCapabilityOnlyWarnsForPossibleSideStories() async throws {
        let model = await makeSignedInRejectionModel()
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c01101",
            isSideStory: false
        )

        await model.refreshLiveChooseDeckRestriction(for: gameID)

        #expect(model.liveChooseDeckRestrictionNotice(for: gameID) == nil)
    }

    @Test("Cancellation leaves live deck restriction unavailable notice unset")
    func cancellationDoesNotBecomeUnavailableRestriction() async throws {
        let service = try SuspendedCatalogService(
            document: loadLiveCampaignCatalog()
        )
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: ScriptedGameLifecycleService(),
            campaignCatalogService: service
        )
        model.sessionState = .signedIn(
            profile: .hosted,
            compatibility: .modern(
                capabilities: [CampaignCatalogAdvertisement.capabilityIdentifier],
                campaignCatalog: advertisement(revision: "1.cancel")
            ),
            user: .sample
        )
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c90020"
        )
        let refresh = Task { await model.refreshLiveChooseDeckRestriction(for: gameID) }
        await service.waitForLoadCount(1)

        refresh.cancel()
        await service.resumeLoad(at: 0)
        await refresh.value

        #expect(model.liveChooseDeckRestrictionNotice(for: gameID) == nil)
    }

    @Test("Stale restriction refresh cannot overwrite a newer scenario result")
    func staleRestrictionRefreshCannotOverwriteNewerScenarioResult() async throws {
        let catalog = try loadLiveCampaignCatalog()
        let service = SuspendedCatalogService(document: catalog)
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: ScriptedGameLifecycleService(),
            campaignCatalogService: service
        )
        model.sessionState = .signedIn(
            profile: .hosted,
            compatibility: .modern(
                capabilities: [CampaignCatalogAdvertisement.capabilityIdentifier],
                campaignCatalog: advertisement(revision: catalog.catalogRevision)
            ),
            user: .sample
        )
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let deck = try sampleRejectedDeck()
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c90020"
        )
        let firstRefresh = Task { await model.refreshLiveChooseDeckRestriction(for: gameID) }
        await service.waitForLoadCount(1)
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c90004"
        )
        let secondRefresh = Task { await model.refreshLiveChooseDeckRestriction(for: gameID) }
        await service.waitForLoadCount(2)

        await service.resumeLoad(at: 1)
        await secondRefresh.value
        await service.resumeLoad(at: 0)
        await firstRefresh.value

        guard case let .requiresInvestigator(requirement)? =
            model.liveChooseDeckRestrictionChecks[gameID]
        else {
            Issue.record("Expected the newer side-story requirement to remain cached")
            return
        }
        #expect(requirement.scenarioID == "90004")
        #expect(model.liveChooseDeckRestrictionDeckError(for: deck, in: gameID) == nil)
    }

    @Test("Restriction checks are cached per game scenario and catalog revision")
    func restrictionChecksAreCachedPerGameScenarioAndRevision() async throws {
        let catalog = try loadLiveCampaignCatalog()
        let service = CountingCatalogService(document: catalog)
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: ScriptedGameLifecycleService(),
            campaignCatalogService: service
        )
        model.sessionState = .signedIn(
            profile: .hosted,
            compatibility: .modern(
                capabilities: [CampaignCatalogAdvertisement.capabilityIdentifier],
                campaignCatalog: advertisement(revision: catalog.catalogRevision)
            ),
            user: .sample
        )
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c90020"
        )

        await model.refreshLiveChooseDeckRestriction(for: gameID)
        await model.refreshLiveChooseDeckRestriction(for: gameID)
        #expect(await service.loadCount() == 1)

        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c90004"
        )
        await model.refreshLiveChooseDeckRestriction(for: gameID)
        #expect(await service.loadCount() == 2)
    }

    @Test("Stored restriction for another scenario does not reject this scenario's deck")
    func scenarioMismatchDoesNotRejectDeck() async throws {
        let model = await makeSignedInRejectionModel()
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try sampleOwnerID()
        let deck = try sampleRejectedDeck()
        _ = installRejectedLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection,
            scenarioID: "c90004"
        )
        model.liveChooseDeckRestrictionChecks[gameID] = .requiresInvestigator(
            LiveChooseDeckRequiredInvestigator(
                scenarioID: "90020",
                investigatorName: "Agnes Baker",
                investigatorCodes: ["01004", "01504", "90017"]
            )
        )

        #expect(model.liveChooseDeckRestrictionDeckError(for: deck, in: gameID) == nil)
    }

    @Test("Missing required investigator name uses generic copy instead of a raw code")
    func missingRequiredInvestigatorNameUsesGenericCopy() throws {
        let document = CampaignCatalogDocument(
            schemaVersion: "1.0.0",
            catalogRevision: "test.missing-name",
            endpoint: "/api/v1/arkham/campaign-catalog",
            digestAlgorithm: "sha256",
            campaigns: [],
            scenarios: [],
            sideStories: [scenarioWithoutRequiredInvestigatorName()]
        )
        let deck = try sampleRejectedDeck()
        let check = LiveChooseDeckRestrictionCatalogLookup.check(for: "c90020", in: document)
        let message = check.rejectionMessage(for: deck, currentScenarioID: "c90020")

        #expect(message == liveChooseDeckLocalized(
            "liveChooseDeck.error.requiresSpecificInvestigator",
            "This scenario requires a specific investigator"
        ))
        #expect(message?.contains("01004") == false)
    }

    @Test("Restriction state is cleared with live game state teardown")
    func restrictionStateIsClearedWithLiveGameStateTeardown() async {
        let model = await makeSignedInRejectionModel()
        let gameID = GameID(UUID())
        model.liveChooseDeckRestrictionChecks[gameID] = .loading
        model.liveChooseDeckRestrictionCacheKeys[gameID] = LiveChooseDeckRestrictionCacheKey(
            scenarioID: "90020",
            isSideStory: true,
            catalogRevision: "test"
        )
        model.liveChooseDeckRestrictionRefreshIDs[gameID] = UUID()

        model.resetLiveGameState()

        #expect(model.liveChooseDeckRestrictionChecks.isEmpty)
        #expect(model.liveChooseDeckRestrictionCacheKeys.isEmpty)
        #expect(model.liveChooseDeckRestrictionRefreshIDs.isEmpty)
    }

    private func scenarioWithoutRequiredInvestigatorName() -> CampaignCatalogScenario {
        CampaignCatalogScenario(
            id: "90020",
            nameKey: "catalogNames.testScenario",
            campaignID: nil,
            alpha: false,
            beta: false,
            dev: false,
            show: true,
            standalone: true,
            returnToID: nil,
            returnToNameKey: nil,
            returnToVariant: false,
            standaloneDifficulties: nil,
            requiredInvestigator: nil,
            requiredInvestigatorCodes: ["01004"],
            deckRequirements: [],
            settings: [],
            parts: []
        )
    }

    private func makeCatalogBackedRejectionModel(
        catalog: CampaignCatalogDocument
    ) async -> AppModel {
        let service = LiveChooseDeckCampaignCatalogService(result: .success(catalog))
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: ScriptedGameLifecycleService(),
            campaignCatalogService: service
        )
        model.sessionState = .signedIn(
            profile: .hosted,
            compatibility: .modern(
                capabilities: [CampaignCatalogAdvertisement.capabilityIdentifier],
                campaignCatalog: advertisement(revision: catalog.catalogRevision)
            ),
            user: .sample
        )
        return model
    }

    private func loadLiveCampaignCatalog() throws -> CampaignCatalogDocument {
        let url = try #require(Bundle.module.url(
            forResource: "campaign-catalog-25a3eb8",
            withExtension: "json",
            subdirectory: "Fixtures/CampaignCatalogLive"
        ))
        return try ContractJSON.decode(
            CampaignCatalogDocument.self,
            from: Data(contentsOf: url)
        )
    }

    private func advertisement(revision: String) -> CampaignCatalogAdvertisement {
        CampaignCatalogAdvertisement(
            endpoint: "/api/v1/arkham/campaign-catalog",
            catalogRevision: revision,
            schemaVersion: "1.0.0",
            digestAlgorithm: "sha256"
        )
    }

    private func rewrittenDeck(
        _ deck: Deck,
        investigatorCode: String,
        investigatorName: String,
        meta: String? = nil
    ) throws -> Deck {
        var object = try #require(
            JSONSerialization.jsonObject(with: ContractJSON.encode(deck)) as? [String: Any]
        )
        var list = try #require(object["list"] as? [String: Any])
        object["investigatorName"] = investigatorName
        list["investigator_code"] = investigatorCode
        list["investigator_name"] = investigatorName
        if let meta {
            list["meta"] = meta
        } else {
            list["meta"] = NSNull()
        }
        object["list"] = list
        object["playList"] = list
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try ContractJSON.decode(Deck.self, from: data)
    }
}

private actor LiveChooseDeckCampaignCatalogService: CampaignCatalogServicing {
    private let result: Result<CampaignCatalogDocument, any Error>

    init(result: Result<CampaignCatalogDocument, any Error>) {
        self.result = result
    }

    func load(
        on _: ServerProfile,
        advertisement _: CampaignCatalogAdvertisement
    ) async throws -> CampaignCatalogDocument {
        try result.get()
    }
}

private actor CountingCatalogService: CampaignCatalogServicing {
    private let document: CampaignCatalogDocument
    private var loads = 0

    init(document: CampaignCatalogDocument) {
        self.document = document
    }

    func load(
        on _: ServerProfile,
        advertisement _: CampaignCatalogAdvertisement
    ) async throws -> CampaignCatalogDocument {
        loads += 1
        return document
    }

    func loadCount() -> Int {
        loads
    }
}

private actor SuspendedCatalogService: CampaignCatalogServicing {
    private struct PendingLoad {
        let id: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let document: CampaignCatalogDocument
    private var pendingLoads: [PendingLoad] = []
    private var startedLoadCount = 0

    init(document: CampaignCatalogDocument) {
        self.document = document
    }

    func load(
        on _: ServerProfile,
        advertisement _: CampaignCatalogAdvertisement
    ) async throws -> CampaignCatalogDocument {
        let id = startedLoadCount
        startedLoadCount += 1
        await withCheckedContinuation { continuation in
            pendingLoads.append(PendingLoad(id: id, continuation: continuation))
        }
        try Task.checkCancellation()
        return document
    }

    func waitForLoadCount(_ count: Int) async {
        while startedLoadCount < count {
            await Task.yield()
        }
    }

    func resumeLoad(at id: Int) {
        guard let index = pendingLoads.firstIndex(where: { $0.id == id }) else { return }
        pendingLoads.remove(at: index).continuation.resume()
    }
}
