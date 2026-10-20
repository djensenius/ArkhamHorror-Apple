@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — live ChooseDeck answers")
// swiftlint:disable:next type_body_length
struct AppModelLiveChooseDeckTests {
    struct LiveChooseDeckFixture: Decodable {
        let deck: Deck
    }

    func sampleDeck() throws -> Deck {
        let url = try #require(
            Bundle.module.url(
                forResource: "decks", withExtension: "json", subdirectory: "Fixtures/Contract"
            )
        )
        return try ContractJSON.decode(LiveChooseDeckFixture.self, from: Data(contentsOf: url)).deck
    }

    func modifiedDeck(_ source: Deck, name: String) -> Deck {
        Deck(
            id: source.id,
            userId: source.userId,
            url: source.url,
            name: name,
            investigatorName: source.investigatorName,
            list: source.list,
            lastUsedAt: source.lastUsedAt,
            overlay: source.overlay,
            playList: source.playList
        )
    }

    func dreamEatersPartAChooseDeckQuestion() throws -> JSONValue {
        let url = try #require(
            Bundle.module.url(
                forResource: "question-dream-eaters-part-a-choose-deck",
                withExtension: "json",
                subdirectory: "Fixtures/LiveDreamEatersPlaythrough"
            )
        )
        return try ContractJSON.decode(JSONValue.self, from: Data(contentsOf: url))
    }

    func dreamEatersPartAChooseDeckPresentation() throws -> QuestionPresentation {
        let url = try #require(
            Bundle.module.url(
                forResource: "question-presentation-dream-eaters-part-a-choose-deck",
                withExtension: "json",
                subdirectory: "Fixtures/LiveDreamEatersPlaythrough"
            )
        )
        return try ContractJSON.decode(QuestionPresentation.self, from: Data(contentsOf: url))
    }

    func makeSignedInModel(
        service: ScriptedGameLifecycleService,
        deckService: any DeckServicing = GameLifecycleDeckService(),
        deckSyncTracker: any DeckSyncTracking = GameLifecycleDeckSyncTracker()
    ) async -> AppModel {
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: service,
            deckService: deckService,
            deckSyncTracker: deckSyncTracker
        )
        model.sessionState = .signedIn(
            profile: .hosted,
            compatibility: .modern(capabilities: []),
            user: .sample
        )
        return model
    }

    func chooseDeckProjection(
        ownerID: PlayerID,
        rawQuestion: JSONValue = .object(["tag": .string("ChooseDeck")]),
        presentation: BoundQuestionPresentation? = nil
    ) -> BoardProjection {
        var questions = UUIDKeyedMap<PlayerIDTag, BasicChoiceQuestionPayload>()
        questions[ownerID] = BasicChoiceQuestionPayload(
            rawValue: rawQuestion,
            state: .updateRequired(tag: "ChooseDeck"),
            presentation: presentation
        )
        let projection = BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot())
        return BoardProjection(
            gameName: projection.gameName,
            hasCampaignContext: projection.hasCampaignContext,
            campaignI18nScope: projection.campaignI18nScope,
            scenario: projection.scenario,
            campaignContinuation: projection.campaignContinuation,
            campaignSummary: projection.campaignSummary,
            acts: projection.acts,
            agendas: projection.agendas,
            locations: projection.locations,
            enemyLocations: projection.enemyLocations,
            investigators: projection.investigators,
            playerOrderCount: projection.playerOrderCount,
            chooseDeckPlayerIDs: projection.chooseDeckPlayerIDs,
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
            focusedChaosTokens: projection.focusedChaosTokens,
            counters: projection.counters,
            skillTest: projection.skillTest,
            questions: questions
        )
    }

    func installLivePrompt(
        on model: AppModel,
        gameID: GameID,
        ownerID: PlayerID,
        participant: LiveGameParticipantIdentity,
        rawQuestion: JSONValue = .object(["tag": .string("ChooseDeck")]),
        presentation: BoundQuestionPresentation? = nil,
        connection: FakeGameSocketConnection
    ) {
        let attemptID = UUID()
        model.liveGameParticipantIdentities[gameID] = participant
        model.liveGameStates[gameID] = .live(chooseDeckProjection(
            ownerID: ownerID,
            rawQuestion: rawQuestion,
            presentation: presentation
        ))
        model.liveGameSessions[gameID] = LiveGameSessionHandle(attemptID: attemptID, task: Task {})
        model.liveGameConnections[gameID] = LiveGameConnectionHandle(
            attemptID: attemptID,
            connectionID: UUID(),
            connection: connection
        )
    }

    func dreamEatersLabelCatalogDocuments() throws -> SyntheticLocaleCatalogDocuments {
        try SyntheticLocaleCatalogDocuments.make(
            entryKeys: ["theDreamEaters.question.chooseDeckForPartA"],
            chunkEntries: """
            {"theDreamEaters.question.chooseDeckForPartA":{"form":"message",\
            "nodes":[{"type":"text","value":"Choose Deck For Part A"}],"variables":[]}}
            """
        )
    }

    @Test(
        "DeckAnswer is sent with the governed shape for the prompt owner",
        .timeLimit(.minutes(1))
    )
    func sendsDeckAnswerForPromptOwner() async throws {
        let service = ScriptedGameLifecycleService()
        let model = await makeSignedInModel(service: service)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let deck = try sampleDeck()
        await connection.enqueueSendResult(.success(()))
        installLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            participant: .participant(ownerID),
            connection: connection
        )

        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))

        let sent = try #require(await connection.sentData.first)
        let decoded = try ContractJSON.decode(DeckAnswer.self, from: sent)
        #expect(decoded == DeckAnswer(deckId: deck.id, playerId: ownerID))
        let object = try ContractJSON.decode(JSONValue.self, from: sent)
        #expect(object == .object([
            "tag": .string("DeckAnswer"),
            "deckId": .string(deck.id.rawValue.uuidString.lowercased()),
            "playerId": .string(ownerID.rawValue.uuidString.lowercased()),
        ]))
    }

    @Test("Live ChooseDeck syncs saved deck before sending", .timeLimit(.minutes(1)))
    func liveChooseDeckSyncsBeforeSending() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = GameLifecycleDeckService()
        let model = await makeSignedInModel(service: service, deckService: deckService)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let deck = try sampleDeck()
        let syncedDeck = modifiedDeck(deck, name: "Synced live deck")
        await deckService.enqueueSync(.success(syncedDeck))
        await connection.enqueueSendResult(.success(()))
        installLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            participant: .participant(ownerID),
            connection: connection
        )

        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))

        #expect(await deckService.syncedIDs == [deck.id])
        #expect(model.deckForChoice(deck, on: .hosted) == syncedDeck)
        let sent = try #require(await connection.sentData.first)
        #expect(try ContractJSON.decode(DeckAnswer.self, from: sent) == DeckAnswer(
            deckId: syncedDeck.id,
            playerId: ownerID
        ))
    }

    @Test("Live ChooseDeck prompt changes during sync stop the send", .timeLimit(.minutes(1)))
    func liveChooseDeckPromptChangeDuringSyncStopsSend() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = GameLifecycleDeckService(syncGated: true)
        let model = await makeSignedInModel(service: service, deckService: deckService)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let deck = try sampleDeck()
        await deckService.enqueueSync(.success(deck))
        await connection.enqueueSendResult(.success(()))
        installLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            participant: .participant(ownerID),
            connection: connection
        )

        let chooseTask = Task { await model.chooseDeckForLivePrompt(deck, in: gameID) }
        await deckService.waitUntilSyncPending(1)
        model.liveGameStates[gameID] = .live(chooseDeckProjection(
            ownerID: ownerID,
            rawQuestion: .object(["tag": .string("ChooseJoinDeck")])
        ))
        await deckService.resumeOldestSync()

        #expect(await chooseTask.value == false)
        #expect(await connection.sentData.isEmpty)
    }

    @Test("Live ChooseDeck sign-out during sync rejects stale writes", .timeLimit(.minutes(1)))
    func liveChooseDeckSignOutDuringSyncRejectsStaleWrites() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = GameLifecycleDeckService(syncGated: true)
        let tracker = GameLifecycleDeckSyncTracker()
        let model = await makeSignedInModel(
            service: service,
            deckService: deckService,
            deckSyncTracker: tracker
        )
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let deck = try sampleDeck()
        let syncedDeck = modifiedDeck(deck, name: "Stale post-sign-out sync")
        await deckService.enqueueSync(.success(syncedDeck))
        await connection.enqueueSendResult(.success(()))
        installLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            participant: .participant(ownerID),
            connection: connection
        )

        let chooseTask = Task { await model.chooseDeckForLivePrompt(deck, in: gameID) }
        await deckService.waitUntilSyncPending(1)
        model.signOut()
        await model.operationTask?.value
        await deckService.resumeOldestSync()

        #expect(await chooseTask.value == false)
        #expect(model.deckForChoice(deck, on: .hosted) == deck)
        #expect(model.deckChoiceSyncNote(for: deck.id, on: .hosted) == nil)
        #expect(await tracker.records.isEmpty)
        #expect(await connection.sentData.isEmpty)
    }

    @Test(
        "Live ChooseDeck session expiry during sync signs out and aborts",
        .timeLimit(.minutes(1))
    )
    func liveChooseDeckSessionExpiryDuringSyncAborts() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = GameLifecycleDeckService()
        let model = await makeSignedInModel(service: service, deckService: deckService)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let deck = try sampleDeck()
        await deckService.enqueueSync(.failure(DeckServiceError.sessionExpired))
        await connection.enqueueSendResult(.success(()))
        installLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            participant: .participant(ownerID),
            connection: connection
        )

        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID) == false)

        #expect(await connection.sentData.isEmpty)
        guard case let .signedOut(profile, compatibility) = model.sessionState,
              profile == .hosted,
              case .modern = compatibility
        else {
            Issue.record("Expected hosted modern signed-out session after sync 401")
            return
        }
    }

    @Test(
        "Live ChooseDeck sync failure sends saved deck and leaves fallback note",
        .timeLimit(.minutes(1))
    )
    func liveChooseDeckSyncFailureLeavesNote() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = GameLifecycleDeckService()
        let model = await makeSignedInModel(service: service, deckService: deckService)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let deck = try sampleDeck()
        await deckService.enqueueSync(.failure(DeckServiceError.transportFailure("offline")))
        await connection.enqueueSendResult(.success(()))
        installLivePrompt(
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            participant: .participant(ownerID),
            connection: connection
        )

        #expect(await model.chooseDeckForLivePrompt(deck, in: gameID))

        #expect(
            model.deckChoiceSyncNote(for: deck.id, on: .hosted) == deckSyncStaleFallbackMessage()
        )
        #expect(await connection.sentData.count == 1)
    }
}
