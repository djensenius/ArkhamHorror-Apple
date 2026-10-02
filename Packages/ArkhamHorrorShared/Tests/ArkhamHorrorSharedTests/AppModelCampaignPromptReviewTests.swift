// swiftlint:disable file_length
@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AppModelCampaignPromptTests {
    func chooseUpgradeDeckProjection(
        ownerID: PlayerID,
        mode: GameMode,
        questionVersion: Int? = nil
    ) throws -> BoardProjection {
        let rawQuestion: JSONValue = .object(["tag": .string("ChooseUpgradeDeck")])
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
        let version = questionVersion ?? base.counters.scenarioSteps
        let presentation = QuestionPresentation(
            protocolVersion: QuestionPresentation.supportedProtocolVersion,
            questionVersion: version,
            questionKind: .chooseUpgradeDeck,
            choiceCount: 0,
            choices: [],
            answer: .deck(tags: ["DeckAnswer"])
        )
        var questions = UUIDKeyedMap<PlayerIDTag, BasicChoiceQuestionPayload>()
        questions[ownerID] = try BasicChoiceQuestionPayload(
            rawValue: rawQuestion,
            state: .updateRequired(tag: "ChooseUpgradeDeck"),
            presentation: presentation.bind(
                to: rawQuestion,
                expectedQuestionVersion: version
            )
        )
        return campaignPromptProjection(
            base: base,
            questions: questions,
            counters: questionVersion.map {
                campaignPromptCounters(base: base.counters, scenarioSteps: $0)
            }
        )
    }

    func campaignPromptCounters(
        base: BoardCounters,
        scenarioSteps: Int
    ) -> BoardCounters {
        BoardCounters(
            totalDoom: base.totalDoom,
            totalClues: base.totalClues,
            encounterDeckSize: base.encounterDeckSize,
            scenarioSteps: scenarioSteps,
            playerCount: base.playerCount,
            phase: base.phase,
            phaseStepSummary: base.phaseStepSummary,
            gameStateSummary: base.gameStateSummary,
            inSetup: base.inSetup,
            inAction: base.inAction,
            pendingPromptCount: base.pendingPromptCount,
            entityCounters: base.entityCounters
        )
    }

    @Test("ChooseUpgradeDeck owner can open and submit while spectators cannot")
    func chooseUpgradeDeckPromptAuthorityUsesOwnerIdentity() async throws {
        let gameService = ScriptedGameLifecycleService()
        let deckService = CampaignPromptDeckService()
        let model = await makeSignedInModel(
            gameService: gameService,
            deckService: deckService
        )
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let projection = try chooseUpgradeDeckProjection(
            ownerID: ownerID,
            mode: campaignMode(canUpgradeDecks: true)
        )
        installPrompt(
            projection,
            on: model,
            gameID: gameID,
            ownerID: ownerID,
            connection: connection
        )

        let ownerPrompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(ownerPrompt.readOnlyReason == .updateRequired)
        #expect(ownerPrompt.statusMessage == nil)
        #expect(!ownerPrompt.canSubmit)
        #expect(ownerPrompt.canUseCampaignDeckPrompt)

        try await deckService.enqueueFetch(.success(deckListFixture()))
        await gameService.enqueueChooseDeckResult(.success(()))
        #expect(await model.upgradeCampaignDeck(
            from: "https://arkhamdb.com/decklist/view/4242",
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: ownerPrompt.identity
        ) == .submitted)
        await gameService.enqueueChooseDeckResult(.success(()))
        #expect(await model.continueCampaignWithoutUpgrading(
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: ownerPrompt.identity
        ) == .submitted)

        model.liveGameParticipantIdentities[gameID] = .spectator
        let spectatorPrompt = try #require(model.basicChoicePresentation(for: gameID))
        #expect(spectatorPrompt.readOnlyReason == .spectator)
        #expect(
            spectatorPrompt.statusMessage
                == "Spectators can view this prompt but cannot answer it."
        )
        #expect(!spectatorPrompt.canUseCampaignDeckPrompt)
    }

    @Test("ContinueCampaign without CampaignStepAnswer remains update-required and cannot send")
    func continueCampaignWithoutCampaignStepAnswerCannotSend() async throws {
        let service = ScriptedGameLifecycleService()
        let model = await makeSignedInModel(gameService: service)
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ))
        let projection = try continuationProjection(
            ownerID: ownerID,
            mode: campaignOnlyMode(),
            answerTags: ["RetireInvestigatorAnswer"]
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

        #expect(prompt.readOnlyReason == .updateRequired)
        #expect(!prompt.isRenderableQuestion)
        #expect(await model.submitContinueCampaignAnswer(
            prompt.identity,
            step: continuation.nextStep
        ) == .readOnly)
        #expect(await connection.sentData.isEmpty)
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

    @Test("arkham.build share URL fetches from the API share endpoint and preserves deckList.url")
    func arkhamBuildShareURLSubmitsAPIShareURL() async throws {
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
            from: "https://arkham.build/share/abc123",
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: prompt.identity
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
            from: "https://arkham.build/decklist/view/abc123",
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: prompt.identity
        )

        #expect(result == .submitted)
        let fetchURL = "https://api.arkham.build/v1/public/share/abc123?type=decklist"
        #expect(await deckService.lastFetchRequest == FetchDeckRequest(url: fetchURL))
        let request = try #require(await gameService.lastChooseDeckRequest)
        #expect(request.deckUrl == fetchURL)
        #expect(request.deckList == DeckListInput(deckList, urlOverride: fetchURL))
    }

    @Test("Stale ChooseUpgradeDeck prompt version cannot submit")
    func staleChooseUpgradeDeckPromptVersionCannotSubmit() async throws {
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
        let stalePrompt = try #require(model.basicChoicePresentation(for: gameID))
        model.liveGameStates[gameID] = try .live(chooseUpgradeDeckProjection(
            ownerID: ownerID,
            mode: campaignMode(canUpgradeDecks: true),
            questionVersion: stalePrompt.questionVersion + 1
        ))

        let result = await model.continueCampaignWithoutUpgrading(
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: stalePrompt.identity
        )

        #expect(result == .failed(
            "This deck prompt changed. Review the game and try again."
        ))
        #expect(await gameService.lastChooseDeckRequest == nil)
    }

    @Test("ChooseUpgradeDeck submission requires local prompt owner")
    func chooseUpgradeDeckSubmissionRequiresLocalPromptOwner() async throws {
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

        model.liveGameParticipantIdentities[gameID] = .spectator
        #expect(await model.continueCampaignWithoutUpgrading(
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: prompt.identity
        ) == .failed(
            "This deck prompt changed. Review the game and try again."
        ))

        let otherID = try PlayerID(#require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        ))
        model.liveGameParticipantIdentities[gameID] = .participant(otherID)
        #expect(await model.continueCampaignWithoutUpgrading(
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: prompt.identity
        ) == .failed(
            "This deck prompt changed. Review the game and try again."
        ))
        #expect(await gameService.lastChooseDeckRequest == nil)
    }

    @Test("ChooseUpgradeDeck prompt change during fetch blocks the PUT")
    func chooseUpgradeDeckPromptChangeDuringFetchBlocksPut() async throws {
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
        await deckService.setFetchGated(true)
        let deckList = try deckListFixture()

        let submission = Task { @MainActor in
            await model.upgradeCampaignDeck(
                from: "https://arkhamdb.com/decklist/view/4242",
                investigatorId: "c01001",
                in: gameID,
                promptIdentity: prompt.identity
            )
        }
        await deckService.waitUntilFetchPending(1)
        model.liveGameStates[gameID] = try .live(chooseUpgradeDeckProjection(
            ownerID: ownerID,
            mode: campaignMode(canUpgradeDecks: true),
            questionVersion: prompt.questionVersion + 1
        ))
        await deckService.resumeOldestFetch(with: .success(deckList))

        #expect(await submission.value == .failed(
            "This deck prompt changed. Review the game and try again."
        ))
        #expect(await gameService.lastChooseDeckRequest == nil)
    }

    @Test("ChooseUpgradeDeck submission requires investigator ownership")
    func chooseUpgradeDeckSubmissionRequiresInvestigatorOwnership() async throws {
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

        let result = await model.continueCampaignWithoutUpgrading(
            investigatorId: "c99999",
            in: gameID,
            promptIdentity: prompt.identity
        )

        #expect(result == .failed(
            "This investigator is no longer yours to update."
        ))
        #expect(await gameService.lastChooseDeckRequest == nil)
    }

    @Test("ChooseUpgradeDeck duplicate taps are deduplicated while the first is in flight")
    func chooseUpgradeDeckDuplicateTapsDeduplicateInFlightSubmission() async throws {
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
        await deckService.setFetchGated(true)
        let deckList = try deckListFixture()

        let firstSubmission = Task { @MainActor in
            await model.upgradeCampaignDeck(
                from: "https://arkhamdb.com/decklist/view/4242",
                investigatorId: "c01001",
                in: gameID,
                promptIdentity: prompt.identity
            )
        }
        await deckService.waitUntilFetchPending(1)

        let duplicate = await model.upgradeCampaignDeck(
            from: "https://arkhamdb.com/decklist/view/4242",
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: prompt.identity
        )

        #expect(duplicate == .failed("A deck update is already being submitted."))
        await gameService.enqueueChooseDeckResult(.success(()))
        await deckService.resumeOldestFetch(with: .success(deckList))
        #expect(await firstSubmission.value == .submitted)
        let request = try #require(await gameService.lastChooseDeckRequest)
        #expect(request.investigatorId.rawValue == "c01001")
    }

    @Test("Campaign prompt client errors localize in German")
    func campaignPromptClientErrorsLocalizeInGerman() async throws {
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

        let invalidLinkMessage = "Gib eine https-ArkhamDB-Deck-/Decklisten-URL "
            + "oder arkham.build-Deck-/Share-URL ein."
        await CampaignPromptLocalization.$localizationIdentifierOverride.withValue("de") {
            #expect(await model.upgradeCampaignDeck(
                from: "not a deck URL",
                investigatorId: "c01001",
                in: gameID,
                promptIdentity: prompt.identity
            ) == .failed(invalidLinkMessage))

            await deckService.enqueueFetch(.failure(DeckServiceError.transportFailure("offline")))
            #expect(await model.upgradeCampaignDeck(
                from: "https://arkhamdb.com/decklist/view/4242",
                investigatorId: "c01001",
                in: gameID,
                promptIdentity: prompt.identity
            ) == .failed(
                "Der Server konnte dieses Deck nicht abrufen. Versuche es erneut."
            ))

            await gameService.enqueueChooseDeckResult(.failure(GameLifecycleError.malformedPayload))
            #expect(await model.continueCampaignWithoutUpgrading(
                investigatorId: "c01001",
                in: gameID,
                promptIdentity: prompt.identity
            ) == .failed(
                "Der Server konnte dieses Deck nicht aktualisieren. Versuche es erneut."
            ))
        }
    }

    @Test("Campaign deck fetch surfaces server-authored operation messages verbatim")
    func campaignDeckFetchSurfacesServerAuthoredOperationMessage() async throws {
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
        let message = "Fetch rejected: server details"
        await deckService.enqueueFetch(.failure(
            DeckServiceError.operationFailed(DeckOperationError(errorMsg: message))
        ))

        let result = await model.upgradeCampaignDeck(
            from: "https://arkhamdb.com/decklist/view/4242",
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: prompt.identity
        )

        #expect(result == .failed(message))
        #expect(await gameService.lastChooseDeckRequest == nil)
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
        let message = "Could not upgrade deck: server details"
        try await deckService.enqueueFetch(.success(deckListFixture()))
        await gameService.enqueueChooseDeckResult(.failure(
            GameLifecycleError.operationFailed(DeckOperationError(errorMsg: message))
        ))

        let result = await model.upgradeCampaignDeck(
            from: "https://arkhamdb.com/decklist/view/4242",
            investigatorId: "c01001",
            in: gameID,
            promptIdentity: prompt.identity
        )

        #expect(result == .failed(message))
    }
}

// swiftlint:enable file_length
