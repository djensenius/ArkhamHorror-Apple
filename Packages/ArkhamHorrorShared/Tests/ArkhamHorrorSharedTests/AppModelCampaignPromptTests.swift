@testable import ArkhamHorrorShared
import Foundation
import Testing

private actor CampaignPromptDeckService: DeckServicing {
    private(set) var lastFetchRequest: FetchDeckRequest?
    private(set) var callOrder: [String] = []
    private var fetchQueue: [Result<DeckList, any Error>] = []

    func enqueueFetch(_ result: Result<DeckList, any Error>) {
        fetchQueue.append(result)
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

private func campaignPromptProjection(
    base: BoardProjection,
    questions: UUIDKeyedMap<PlayerIDTag, BasicChoiceQuestionPayload>
) -> BoardProjection {
    BoardProjection(
        gameName: base.gameName,
        hasCampaignContext: base.hasCampaignContext,
        scenario: base.scenario,
        campaignContinuation: base.campaignContinuation,
        acts: base.acts,
        agendas: base.agendas,
        locations: base.locations,
        enemyLocations: base.enemyLocations,
        investigators: base.investigators,
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
        counters: base.counters,
        skillTest: base.skillTest,
        questions: questions
    )
}

@MainActor
@Suite("AppModel — campaign prompts")
struct AppModelCampaignPromptTests {
    private func makeSignedInModel(
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

    private func campaignOnlyMode() throws -> GameMode {
        let url = try #require(Bundle.module.url(
            forResource: "mode-campaign-only",
            withExtension: "json",
            subdirectory: "Fixtures/Contract"
        ))
        return try ContractJSON.decode(GameMode.self, from: Data(contentsOf: url))
    }

    private func campaignMode(
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

    private func campaignAnswerBytes(step: JSONValue) throws -> Data {
        try ContractJSON.encode(CampaignStepAnswer(contents: step))
    }

    private func deckListFixture() throws -> DeckList {
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

    private func continuationProjection(
        ownerID: PlayerID,
        mode: GameMode,
        rawQuestion: JSONValue = .object(["tag": .string("ContinueCampaign")])
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
            answer: .continueCampaign(tags: ["CampaignStepAnswer"])
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

    private func installPrompt(
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
        #expect(continuation.canUpgrade)
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

    @Test("Upgrade deck wrapper is fenced off when the server flag is false")
    func upgradeDeckWrapperRequiresServerFlag() async throws {
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
        #expect(!continuation.canUpgradeDecks)
        #expect(!continuation.canUpgrade)
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
        ) == .unsupportedChoice)
        #expect(await connection.sentData.isEmpty)
    }

    @Test("ContinueCampaign rejects an unsupported made-up step")
    func continueCampaignRejectsUnsupportedStep() async throws {
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
            step: .object(["tag": .string("MadeUpStep")])
        ) == .unsupportedChoice)
        #expect(await connection.sentData.isEmpty)
    }

    @Test("ContinueCampaign transport failure retries the exact campaign answer")
    func continueCampaignRetryResendsExactCampaignAnswer() async throws {
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
        let expected = try campaignAnswerBytes(step: continuation.nextStep)
        await connection.enqueueSendResult(.failure(GameSocketTransportError()))
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
        ) == .retryableFailure)
        #expect(await connection.sentData == [expected])
        let retryPrompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(retryPrompt.canRetry)
        #expect(await model.submitContinueCampaignAnswer(
            retryPrompt.identity,
            step: continuation.nextStep
        ) == .alreadyPending)
        #expect(await connection.sentData == [expected])

        await connection.enqueueSendResult(.success(()))
        #expect(await model.retryBasicChoice(retryPrompt.identity) == .sentAwaitingSnapshot)
        #expect(await connection.sentData == [expected, expected])
    }

    @Test("ContinueCampaign presentation exposes server rejection feedback")
    func continueCampaignPresentationSurfacesServerFeedback() async throws {
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
        installPrompt(
            projection,
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        let connectionID = try #require(model.liveGameConnections[gameID]?.connectionID)
        model.basicChoiceActions[gameID] = BasicChoiceActionRecord(
            identity: prompt.identity,
            submission: .continueCampaign(continuation.nextStep),
            attemptID: UUID(),
            connectionID: connectionID,
            phase: .retryable(.serverRejected)
        )
        model.basicChoiceServerFeedback[gameID] = "The server rejected that campaign step."

        let rejected = try #require(model.basicChoicePresentation(for: gameID))
        #expect(rejected.canRetry)
        #expect(rejected.statusMessage == "The server rejected this choice. Try again.")
        #expect(rejected.serverFeedback == "The server rejected that campaign step.")
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
        let deckList = try deckListFixture()
        await deckService.enqueueFetch(.success(deckList))
        await gameService.enqueueChooseDeckResult(.success(()))

        let result = await model.upgradeCampaignDeck(
            from: "https://arkhamdb.com/decklist/view/4242",
            investigatorId: "c01001",
            in: gameID
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

    @Test("arkham.build share URL fetches from the API share endpoint and preserves deckList.url")
    func arkhamBuildShareURLSubmitsAPIShareURL() async throws {
        let gameService = ScriptedGameLifecycleService()
        let deckService = CampaignPromptDeckService()
        let model = await makeSignedInModel(
            gameService: gameService,
            deckService: deckService
        )
        let gameID = GameID(UUID())
        let deckList = try deckListFixture()
        await deckService.enqueueFetch(.success(deckList))
        await gameService.enqueueChooseDeckResult(.success(()))

        let result = await model.upgradeCampaignDeck(
            from: "https://arkham.build/share/abc123",
            investigatorId: "c01001",
            in: gameID
        )

        #expect(result == .submitted)
        let fetchURL = "https://api.arkham.build/v1/public/share/abc123"
        #expect(await deckService.lastFetchRequest == FetchDeckRequest(url: fetchURL))
        let request = try #require(await gameService.lastChooseDeckRequest)
        #expect(request.deckUrl == fetchURL)
        #expect(request.deckList == DeckListInput(deckList, urlOverride: fetchURL))
    }

    @Test("arkham.build decklist URL fetches from the API share decklist endpoint")
    func arkhamBuildDecklistURLSubmitsAPIShareDecklistURL() async throws {
        let gameService = ScriptedGameLifecycleService()
        let deckService = CampaignPromptDeckService()
        let model = await makeSignedInModel(
            gameService: gameService,
            deckService: deckService
        )
        let gameID = GameID(UUID())
        let deckList = try deckListFixture()
        await deckService.enqueueFetch(.success(deckList))
        await gameService.enqueueChooseDeckResult(.success(()))

        let result = await model.upgradeCampaignDeck(
            from: "https://arkham.build/decklist/view/abc123",
            investigatorId: "c01001",
            in: gameID
        )

        #expect(result == .submitted)
        let fetchURL = "https://api.arkham.build/v1/public/share/abc123?type=decklist"
        #expect(await deckService.lastFetchRequest == FetchDeckRequest(url: fetchURL))
        let request = try #require(await gameService.lastChooseDeckRequest)
        #expect(request.deckUrl == fetchURL)
        #expect(request.deckList == DeckListInput(deckList, urlOverride: fetchURL))
    }

    @Test("Campaign deck upgrade surfaces server deck endpoint messages")
    func campaignDeckUpgradeSurfacesServerDeckEndpointMessage() async throws {
        let gameService = ScriptedGameLifecycleService()
        let deckService = CampaignPromptDeckService()
        let model = await makeSignedInModel(
            gameService: gameService,
            deckService: deckService
        )
        let gameID = GameID(UUID())
        let message = "Could not upgrade deck: server details"
        await deckService.enqueueFetch(.success(try deckListFixture()))
        await gameService.enqueueChooseDeckResult(.failure(
            GameLifecycleError.operationFailed(DeckOperationError(errorMsg: message))
        ))

        let result = await model.upgradeCampaignDeck(
            from: "https://arkhamdb.com/decklist/view/4242",
            investigatorId: "c01001",
            in: gameID
        )

        #expect(result == .failed(message))
    }

    @Test("Continue without upgrading PUTs a nil deck source to the game deck endpoint")
    func continueWithoutUpgradingSubmitsNilDeckSource() async throws {
        let gameService = ScriptedGameLifecycleService()
        let model = await makeSignedInModel(gameService: gameService)
        let gameID = GameID(UUID())
        await gameService.enqueueChooseDeckResult(.success(()))

        let result = await model.continueCampaignWithoutUpgrading(
            investigatorId: "c01001",
            in: gameID
        )

        #expect(result == .submitted)
        let request = try #require(await gameService.lastChooseDeckRequest)
        #expect(request.investigatorId.rawValue == "c01001")
        #expect(request.deckUrl == nil)
        #expect(request.deckList == nil)
    }
}
