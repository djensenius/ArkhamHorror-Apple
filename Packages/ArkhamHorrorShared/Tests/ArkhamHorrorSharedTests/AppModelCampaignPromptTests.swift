// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

actor CampaignPromptDeckService: DeckServicing {
    private(set) var lastFetchRequest: FetchDeckRequest?
    private(set) var callOrder: [String] = []
    private var fetchQueue: [Result<DeckList, any Error>] = []
    private var isFetchGated = false
    private var fetchContinuations: [CheckedContinuation<DeckList, any Error>] = []
    private var fetchPendingWaiters: [
        (threshold: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func enqueueFetch(_ result: Result<DeckList, any Error>) {
        fetchQueue.append(result)
    }

    func setFetchGated(_ gated: Bool) {
        isFetchGated = gated
    }

    func waitUntilFetchPending(_ count: Int) async {
        if fetchContinuations.count >= count {
            return
        }
        await withCheckedContinuation { fetchPendingWaiters.append((count, $0)) }
    }

    func resumeOldestFetch(with result: Result<DeckList, any Error>) {
        guard !fetchContinuations.isEmpty else { return }
        let continuation = fetchContinuations.removeFirst()
        switch result {
        case let .success(value): continuation.resume(returning: value)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    private func notifyFetchWaiters() {
        fetchPendingWaiters.removeAll { entry in
            guard fetchContinuations.count >= entry.threshold else { return false }
            entry.continuation.resume()
            return true
        }
    }

    private func consume<T>(_ queue: inout [Result<T, any Error>]) throws -> T {
        guard !queue.isEmpty else { throw TestFailure() }
        return try queue.removeFirst().get()
    }

    func listDecks(on _: ServerProfile, token _: String) async throws -> DeckListResponse {
        throw TestFailure()
    }

    func fetchDeckList(
        _ request: FetchDeckRequest, on _: ServerProfile, token _: String
    ) async throws -> DeckList {
        callOrder.append("fetchDeckList")
        lastFetchRequest = request
        if isFetchGated {
            return try await withCheckedThrowingContinuation { continuation in
                fetchContinuations.append(continuation)
                notifyFetchWaiters()
            }
        }
        return try consume(&fetchQueue)
    }

    func createDeck(
        _: CreateDeckRequest, on _: ServerProfile, token _: String
    ) async throws -> Deck {
        throw TestFailure()
    }

    func importDeck(
        from _: String, on _: ServerProfile, token _: String
    ) async throws -> Deck {
        throw TestFailure()
    }

    func deleteDeck(_: DeckID, on _: ServerProfile, token _: String) async throws {
        throw TestFailure()
    }

    func validateDeckList(
        _: DeckListInput, on _: ServerProfile, token _: String
    ) async throws -> DeckValidationSuccess {
        throw TestFailure()
    }
}

private struct CampaignPromptDeckFixture: Decodable {
    let normalizedDeckList: DeckList
}

func campaignPromptProjection(
    base: BoardProjection,
    questions: UUIDKeyedMap<PlayerIDTag, BasicChoiceQuestionPayload>,
    counters: BoardCounters? = nil
) -> BoardProjection {
    BoardProjection(
        gameName: base.gameName,
        hasCampaignContext: base.hasCampaignContext,
        campaignI18nScope: base.campaignI18nScope,
        scenario: base.scenario,
        campaignContinuation: base.campaignContinuation,
        campaignSummary: base.campaignSummary,
        acts: base.acts,
        agendas: base.agendas,
        locations: base.locations,
        enemyLocations: base.enemyLocations,
        investigators: base.investigators,
        playerOrderCount: base.playerOrderCount,
        chooseDeckPlayerIDs: base.chooseDeckPlayerIDs,
        enemyIDs: base.enemyIDs,
        treacheryIDs: base.treacheryIDs,
        treacheriesByID: base.treacheriesByID,
        otherInvestigatorCount: base.otherInvestigatorCount,
        killedInvestigatorCount: base.killedInvestigatorCount,
        handCardsByPlayer: base.handCardsByPlayer,
        orderedHandCardsByPlayer: base.orderedHandCardsByPlayer,
        inPlayCardsByPlayer: base.inPlayCardsByPlayer,
        threatTreacheriesByPlayer: base.threatTreacheriesByPlayer,
        enemiesByLocationID: base.enemiesByLocationID,
        engagedEnemiesByInvestigatorID: base.engagedEnemiesByInvestigatorID,
        chaosBag: base.chaosBag,
        focusedChaosTokens: base.focusedChaosTokens,
        counters: counters ?? base.counters,
        skillTest: base.skillTest,
        questions: questions
    )
}

@MainActor
@Suite("AppModel — campaign prompts")
// swiftlint:disable:next type_body_length
struct AppModelCampaignPromptTests {
    func makeSignedInModel(
        gameService: ScriptedGameLifecycleService,
        deckService: CampaignPromptDeckService = CampaignPromptDeckService()
    ) async -> AppModel {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "session-token"])
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(
                currentUserResult: .success(.sample)
            ),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: gameService,
            deckService: deckService
        )
        await model.flowTask?.value
        model.sessionState = .signedIn(
            profile: .hosted,
            compatibility: .modern(capabilities: []),
            user: .sample
        )
        return model
    }

    func campaignOnlyMode() throws -> GameMode {
        let url = try #require(Bundle.module.url(
            forResource: "mode-campaign-only",
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        return try ContractJSON.decode(GameMode.self, from: Data(contentsOf: url))
    }

    func campaignMode(
        canUpgradeDecks: Bool,
        nextStep: JSONValue = .object(["tag": .string("PrologueStep")]),
        completedSteps: [JSONValue] = []
    ) -> GameMode {
        .campaignOnly(.object([
            "completedSteps": .array(completedSteps),
            "step": .object([
                "tag": .string("ContinueCampaignStep"),
                "contents": .object([
                    "canChooseSideStory": .bool(false),
                    "canUpgradeDecks": .bool(canUpgradeDecks),
                    "chooseSideStory": .bool(false),
                    "nextStep": nextStep,
                ]),
            ]),
        ]))
    }

    func campaignAnswerBytes(step: JSONValue) throws -> Data {
        try ContractJSON.encode(CampaignStepAnswer(contents: step))
    }

    func deckListFixture() throws -> DeckList {
        let url = try #require(Bundle.module.url(
            forResource: "decks",
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        return try ContractJSON.decode(
            CampaignPromptDeckFixture.self,
            from: Data(contentsOf: url)
        ).normalizedDeckList
    }

    func deckListFixture(
        investigatorCode: String,
        investigatorName: String,
        deckURL: String? = nil,
        deckName: String? = nil
    ) throws -> DeckList {
        var deckList = try deckListFixture()
        deckList = try DeckList(
            slots: deckList.slots,
            sideSlots: deckList.sideSlots,
            investigatorCode: CardCode(investigatorCode),
            investigatorName: investigatorName,
            meta: deckList.meta,
            tabooId: deckList.tabooId,
            url: deckURL,
            id: deckList.id,
            name: deckName ?? deckList.name
        )
        return deckList
    }

    func continuationProjection(
        ownerID: PlayerID,
        mode: GameMode,
        rawQuestion: JSONValue = .object(["tag": .string("ContinueCampaign")]),
        answerTags: [String] = ["CampaignStepAnswer"]
    ) throws -> BoardProjection {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        let snapshot = BoardTestFixtures.snapshot(
            mode: mode,
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    playerID: ownerID,
                    spentXp: 2,
                    experiencePoints: 5
                ),
            ],
            playerOrder: [investigatorID]
        )
        let base = BoardProjectionBuilder.makeProjection(from: snapshot)
        let presentation = QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: base.counters.scenarioSteps,
            questionKind: .continueCampaign,
            choiceCount: 0,
            choices: [],
            answer: .continueCampaign(tags: answerTags)
        )
        var questions = UUIDKeyedMap<PlayerIDTag, BasicChoiceQuestionPayload>()
        questions[ownerID] = try BasicChoiceQuestionPayload(
            rawValue: rawQuestion,
            state: .updateRequired(tag: "ContinueCampaign"),
            presentation: presentation.bind(
                to: rawQuestion,
                expectedQuestionVersion: base.counters.scenarioSteps
            )
        )
        return campaignPromptProjection(base: base, questions: questions)
    }

    func installPrompt(
        _ projection: BoardProjection,
        on model: AppModel,
        gameID: GameID,
        ownerID: PlayerID,
        connection: FakeGameSocketConnection
    ) {
        let attemptID = UUID()
        model.liveGameStates[gameID] = .live(projection)
        model.liveGameParticipantIdentities[gameID] = .participant(ownerID)
        model.liveGameSessions[gameID] = LiveGameSessionHandle(
            attemptID: attemptID,
            task: Task {}
        )
        model.liveGameConnections[gameID] = LiveGameConnectionHandle(
            attemptID: attemptID,
            connectionID: UUID(),
            connection: connection
        )
    }

    @Test("ContinueCampaign sends the server-provided nextStep from the campaign fixture")
    func sendsServerProvidedCampaignStepAnswer() async throws {
        let service = ScriptedGameLifecycleService()
        let model = await makeSignedInModel(gameService: service)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let projection = try continuationProjection(
            ownerID: ownerID,
            mode: campaignOnlyMode()
        )
        let continuation = try #require(projection.campaignContinuation)
        #expect(projection.investigators.first?.availableExperience == 3)
        await connection.enqueueSendResult(.success(()))
        installPrompt(
            projection,
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))

        #expect(await model.submitContinueCampaignAnswer(
            prompt.identity,
            step: continuation.nextStep
        ) == .sentAwaitingSnapshot)

        let sent = try #require(await connection.sentData.first)
        let object = try ContractJSON.decode(JSONValue.self, from: sent)
        #expect(object == .object([
            "tag": .string("CampaignStepAnswer"),
            "contents": .object(["tag": .string("PrologueStep")]),
        ]))
    }

    @Test("Upgrade deck transition sends the web CampaignStepAnswer wrapper")
    func sendsUpgradeDeckCampaignStepWrapper() async throws {
        let service = ScriptedGameLifecycleService()
        let model = await makeSignedInModel(gameService: service)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let projection = try continuationProjection(
            ownerID: ownerID,
            mode: campaignMode(
                canUpgradeDecks: true,
                completedSteps: [.object(["tag": .string("ScenarioStep")])]
            )
        )
        let continuation = try #require(projection.campaignContinuation)
        #expect(continuation.canUpgradeDecks)
        await connection.enqueueSendResult(.success(()))
        installPrompt(
            projection,
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))

        #expect(await model.submitContinueCampaignAnswer(
            prompt.identity,
            step: continuation.upgradeStep
        ) == .sentAwaitingSnapshot)

        let sent = try #require(await connection.sentData.first)
        let object = try ContractJSON.decode(JSONValue.self, from: sent)
        #expect(object == .object([
            "tag": .string("CampaignStepAnswer"),
            "contents": .object([
                "tag": .string("UpgradeDeckStep"),
                "contents": .object([
                    "tag": .string("ContinueCampaignStep"),
                    "contents": .object([
                        "canUpgradeDecks": .bool(true),
                        "nextStep": .object(["tag": .string("PrologueStep")]),
                    ]),
                ]),
            ]),
        ]))
    }

    @Test("Upgrade deck URL fetches then PUTs the game deck body")
    func upgradeDeckURLSubmitsFetchedDeckListToGameDeckEndpoint() async throws {
        let gameService = ScriptedGameLifecycleService()
        let deckService = CampaignPromptDeckService()
        let model = await makeSignedInModel(
            gameService: gameService,
            deckService: deckService
        )
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        try installPrompt(
            chooseUpgradeDeckProjection(
                ownerID: ownerID,
                mode: campaignMode(canUpgradeDecks: true)
            ),
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: FakeGameSocketConnection()
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let deckList = try deckListFixture()
        await deckService.enqueueFetch(.success(deckList))
        await gameService.enqueueChooseDeckResult(.success(()))

        let result = await model.upgradeCampaignDeck(
            from: "https://arkhamdb.com/decklist/view/4242",
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: prompt.identity
        )

        #expect(result == .submitted)
        #expect(await deckService.lastFetchRequest == FetchDeckRequest(
            url: "https://arkhamdb.com/api/public/decklist/4242"
        ))
        let request = try #require(await gameService.lastChooseDeckRequest)
        #expect(request.investigatorId.rawValue == "c01001")
        #expect(request.deckUrl == "https://arkhamdb.com/api/public/decklist/4242")
        #expect(request.deckList == DeckListInput(
            deckList,
            urlOverride: "https://arkhamdb.com/api/public/decklist/4242"
        ))
    }

    func contractFixtureData(named fileName: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: fileName,
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        return try Data(contentsOf: url)
    }

    func replacingFirst(
        _ needle: String,
        with replacement: String,
        in haystack: String
    ) throws -> String {
        let range = try #require(haystack.range(of: needle))
        var result = haystack
        result.replaceSubrange(range, with: replacement)
        return result
    }

    func upgradedDeckServerEnvelope() throws -> GetGameEnvelope {
        var snapshotText = try #require(
            String(data: contractFixtureData(named: "get-game"), encoding: .utf8)
        )
        let replacements = [
            ("\"deckUrl\": null", "\"deckUrl\": \"https://server.example/upgraded-deck\""),
            ("\"xp\": 0", "\"xp\": 8"),
            ("\"spentXp\": 0", "\"spentXp\": 3"),
            ("\"physicalTrauma\": 0", "\"physicalTrauma\": 1"),
            ("\"mentalTrauma\": 0", "\"mentalTrauma\": 2"),
        ]
        for (needle, replacement) in replacements {
            snapshotText = try replacingFirst(needle, with: replacement, in: snapshotText)
        }
        return try ContractJSON.decode(GetGameEnvelope.self, from: Data(snapshotText.utf8))
    }

    @Test("Server-captured replacement ChooseUpgradeDeck bytes require replacement and hide skip")
    func capturedReplacementChooseUpgradeDeckRequiresReplacementAndHidesSkip() throws {
        let envelope = try campaignPromptFixtureEnvelope(
            named: "campaign-replacement-choose-upgrade-deck"
        )
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        let investigator = try #require(projection.investigators.first)
        let context = CampaignUpgradeDeckContext.make(
            investigator: investigator,
            campaignSummary: projection.campaignSummary
        )

        #expect(envelope.game.git == "ff0c3b923880117493192a015f5f4b98c7e299e7")
        #expect(envelope.game.id.rawValue.uuidString.lowercased()
            == "f74c263b-7fb6-4b30-b028-ec090f884c4a")
        #expect(projection.campaignSummary?.killedOrInsaneInvestigatorIDs == ["c01001"])
        #expect(context.requiresReplacement)
        #expect(!context.allowsSkip)
        #expect(projection.questions.values.first?.rawValue == .object([
            "tag": .string("ChooseUpgradeDeck"),
        ]))
    }

    @Test("Crossed-out KilledInvestigators entries still require replacement")
    func crossedOutKilledInvestigatorsRequireReplacement() {
        let log: JSONValue = .object([
            "recorded": .array([]),
            "crossedOut": .array([]),
            "recordedCounts": .array([]),
            "recordedSets": .array([
                .array([
                    .object(["tag": .string("KilledInvestigators")]),
                    .array([
                        .object([
                            "recordType": .string("RecordableCardCode"),
                            "recordVal": .object([
                                "tag": .string("CrossedOut"),
                                "contents": .string("c01001"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let summary = BoardCampaignSummaryBuilder.makeLogSummary(from: log)

        #expect(summary.killedOrInsaneInvestigatorIDs == ["c01001"])
    }

    @Test("Server-captured replacement follow-up ContinueCampaign projects living investigator")
    func capturedReplacementFollowUpContinueCampaignAllowsLivingInvestigatorToSkip() throws {
        let envelope = try campaignPromptFixtureEnvelope(
            named: "campaign-replacement-follow-up-continue-campaign"
        )
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        let investigator = try #require(projection.investigators.first)
        let context = CampaignUpgradeDeckContext.make(
            investigator: investigator,
            campaignSummary: projection.campaignSummary
        )

        #expect(Set(envelope.game.investigators.keys.map(\.rawValue.rawValue)) == ["c01002"])
        #expect(try envelope.game.killedInvestigators[InvestigatorID(CardCode("c01001"))] != nil)
        #expect(projection.campaignSummary?.killedOrInsaneInvestigatorIDs == ["c01001"])
        #expect(investigator.id.rawValue.rawValue == "c01002")
        #expect(!context.requiresReplacement)
        #expect(context.allowsSkip)
        #expect(projection.questions.values.first?.rawValue == .object([
            "tag": .string("ContinueCampaign"),
        ]))
    }

    func campaignPromptFixtureEnvelope(named name: String) throws -> GetGameEnvelope {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/CampaignPrompt"
        ))
        return try ContractJSON.decode(GetGameEnvelope.self, from: Data(contentsOf: url))
    }

    @Test("Saved replacement deck PUTs old seat id with the replacement deck list")
    func savedReplacementDeckSubmitsOldSeatAndReplacementDeckList() async throws {
        let gameService = ScriptedGameLifecycleService()
        let model = await makeSignedInModel(gameService: gameService)
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        try installPrompt(
            chooseUpgradeDeckProjection(
                ownerID: ownerID,
                mode: campaignMode(canUpgradeDecks: true)
            ),
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: FakeGameSocketConnection()
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let replacementList = try deckListFixture(
            investigatorCode: "c01002",
            investigatorName: "Daisy Walker",
            deckURL: "https://server.example/decks/daisy",
            deckName: "Daisy replacement"
        )
        let replacementDeck = Deck(
            id: DeckID(UUID()),
            userId: 1,
            url: "https://server.example/decks/daisy",
            name: "Daisy replacement",
            investigatorName: "Daisy Walker",
            list: replacementList
        )
        await gameService.enqueueChooseDeckResult(.success(()))

        let result = await model.upgradeCampaignDeck(
            using: replacementDeck,
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: prompt.identity
        )

        #expect(result == .submitted)
        let request = try #require(await gameService.lastChooseDeckRequest)
        #expect(request.investigatorId.rawValue == "c01001")
        #expect(request.deckUrl == "https://server.example/decks/daisy")
        #expect(request.deckList == DeckListInput(
            replacementList,
            urlOverride: "https://server.example/decks/daisy"
        ))
        #expect(request.deckList?.investigatorCode.rawValue == "c01002")
    }

    @Test("Saved replacement deck surfaces server-authored rejection messages")
    func savedReplacementDeckSurfacesServerRejection() async throws {
        let gameService = ScriptedGameLifecycleService()
        let model = await makeSignedInModel(gameService: gameService)
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        try installPrompt(
            chooseUpgradeDeckProjection(
                ownerID: ownerID,
                mode: campaignMode(canUpgradeDecks: true)
            ),
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: FakeGameSocketConnection()
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let replacementList = try deckListFixture(
            investigatorCode: "c01002",
            investigatorName: "Daisy Walker"
        )
        let replacementDeck = Deck(
            id: DeckID(UUID()),
            userId: 1,
            url: nil,
            name: "Daisy replacement",
            investigatorName: "Daisy Walker",
            list: replacementList
        )
        let message = "That investigator was killed or driven insane and must be replaced"
        await gameService.enqueueChooseDeckResult(.failure(
            GameLifecycleError.operationFailed(DeckOperationError(errorMsg: message))
        ))

        let result = await model.upgradeCampaignDeck(
            using: replacementDeck,
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: prompt.identity
        )

        #expect(result == .failed(message))
        let request = try #require(await gameService.lastChooseDeckRequest)
        #expect(request.investigatorId.rawValue == "c01001")
    }

    @Test("Continue without upgrading PUTs a nil deck source to the game deck endpoint")
    func continueWithoutUpgradingSubmitsNilDeckSource() async throws {
        let gameService = ScriptedGameLifecycleService()
        let model = await makeSignedInModel(gameService: gameService)
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        try installPrompt(
            chooseUpgradeDeckProjection(
                ownerID: ownerID,
                mode: campaignMode(canUpgradeDecks: true)
            ),
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: FakeGameSocketConnection()
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        await gameService.enqueueChooseDeckResult(.success(()))

        let result = await model.continueCampaignWithoutUpgrading(
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: prompt.identity
        )

        #expect(result == .submitted)
        let request = try #require(await gameService.lastChooseDeckRequest)
        #expect(request.investigatorId.rawValue == "c01001")
        #expect(request.deckUrl == nil)
        #expect(request.deckList == nil)
    }

    @Test("After an upgrade, the next real snapshot supplies the deck and XP authority")
    func upgradedDeckNextScenarioComesFromServerSnapshotBytes() async throws {
        let gameService = ScriptedGameLifecycleService()
        let deckService = CampaignPromptDeckService()
        let model = await makeSignedInModel(
            gameService: gameService,
            deckService: deckService
        )
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        try installPrompt(
            chooseUpgradeDeckProjection(
                ownerID: ownerID,
                mode: campaignMode(canUpgradeDecks: true)
            ),
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: FakeGameSocketConnection()
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        try await deckService.enqueueFetch(.success(deckListFixture()))
        await gameService.enqueueChooseDeckResult(.success(()))

        #expect(await model.upgradeCampaignDeck(
            from: "https://arkhamdb.com/decklist/view/4242",
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: prompt.identity
        ) == .submitted)

        let serverEnvelope = try upgradedDeckServerEnvelope()
        let investigatorID = try InvestigatorID(CardCode("c01001"))
        let serverInvestigator = try #require(serverEnvelope.game.investigators[investigatorID])
        #expect(serverInvestigator.deckURL == "https://server.example/upgraded-deck")

        let projection = BoardProjectionBuilder.makeProjection(from: serverEnvelope.game)
        model.liveGameStates[gameID] = .live(projection)
        let projectedInvestigator = try #require(
            model.liveGameState(for: gameID).lastKnownProjection?.investigators.first
        )
        #expect(projectedInvestigator.availableExperience == 5)
        #expect(projectedInvestigator.physicalTrauma == 1)
        #expect(projectedInvestigator.mentalTrauma == 2)
        #expect(projectedInvestigator.experiencePoints == serverInvestigator.experiencePoints)
        #expect(projectedInvestigator.spentExperience == serverInvestigator.spentXp)
        #expect(await gameService.lastChooseDeckRequest?.deckUrl
            == "https://arkhamdb.com/api/public/decklist/4242")
    }
}

// swiftlint:enable file_length
