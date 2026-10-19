@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
extension AppModelDeckSyncChoiceTests {
    @Test(
        "Lobby blocks resolved decks when revalidation fails",
        .timeLimit(.minutes(1)),
        arguments: DeckChoiceValidationSource.allCases, DeckChoiceValidationFailureKind.allCases
    )
    func lobbyBlocksResolvedDeckWhenValidationFails(
        source: DeckChoiceValidationSource,
        failure: DeckChoiceValidationFailureKind
    ) async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = ScriptedDeckService()
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: service, deckService: deckService
        )
        let decks = try await prepareInvalidResolvedDeckChoice(
            model: model, service: deckService, source: source, failure: failure
        )
        let gameID = GameID(UUID())
        await service.enqueueChooseDeckResult(.success(()))
        await service.enqueueListGamesResult(.success([]))

        model.chooseDeck(decks.selected, investigatorId: "01001", in: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value
        await model.gameListTask?.value

        #expect(await service.lastChooseDeckRequest == nil)
        #expect(model.gameLifecycleActions[gameID] == nil)
        #expect(model.deckChoiceSyncNote(for: decks.original.id, on: .hosted) == failure.message)
        await expectResolvedDeckWasValidated(
            decks.resolved, original: decks.original, service: deckService, source: source
        )
    }
}

@MainActor
extension AppModelLiveChooseDeckTests {
    @Test(
        "Live choice blocks resolved decks when revalidation fails",
        .timeLimit(.minutes(1)),
        arguments: DeckChoiceValidationSource.allCases, DeckChoiceValidationFailureKind.allCases
    )
    func liveBlocksResolvedDeckWhenValidationFails(
        source: DeckChoiceValidationSource,
        failure: DeckChoiceValidationFailureKind
    ) async throws {
        let deckService = ScriptedDeckService()
        let model = await makeSignedInModel(
            service: ScriptedGameLifecycleService(), deckService: deckService
        )
        let decks = try await prepareInvalidResolvedDeckChoice(
            model: model, service: deckService, source: source, failure: failure
        )
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = PlayerID(UUID())
        installLivePrompt(
            on: model, gameID: gameID, ownerID: ownerID,
            participant: .participant(ownerID), connection: connection
        )
        await connection.enqueueSendResult(.success(()))

        #expect(await !(model.chooseDeckForLivePrompt(decks.selected, in: gameID)))

        #expect(await connection.sentData.isEmpty)
        #expect(model.basicChoiceActions[gameID] == nil)
        #expect(model.deckChoiceSyncNote(for: decks.original.id, on: .hosted) == failure.message)
        await expectResolvedDeckWasValidated(
            decks.resolved, original: decks.original, service: deckService, source: source
        )
    }

    @Test("Live choice aborts when its token context fails", .timeLimit(.minutes(1)))
    func liveChoiceTokenContextFailureAborts() async throws {
        let deckService = ScriptedDeckService()
        let model = await makeSignedInModel(
            service: ScriptedGameLifecycleService(), deckService: deckService
        )
        let deck = try sampleDeck()
        _ = await validatedDeckChoicePicker(deck: deck, model: model, service: deckService)
        let cached = deckSyncChoiceModifiedDeck(
            deck, url: deck.url, name: "Cached", listName: "New"
        )
        model.recordSyncedDeckForChoice(cached, on: .hosted)
        let tokenStore = try #require(model.tokenStore as? FakeTokenStore)
        await tokenStore.setReadError(TestFailure())
        let connection = FakeGameSocketConnection()
        let gameID = GameID(UUID())
        let ownerID = PlayerID(UUID())
        installLivePrompt(
            on: model, gameID: gameID, ownerID: ownerID,
            participant: .participant(ownerID), connection: connection
        )
        await connection.enqueueSendResult(.success(()))

        #expect(await !(model.chooseDeckForLivePrompt(deck, in: gameID)))

        #expect(await connection.sentData.isEmpty)
        #expect(await deckService.syncedIDs.isEmpty)
        #expect(await deckService.validatedDeckLists == [DeckListInput(deck.playableList)])
        #expect(model.basicChoiceActions[gameID] == nil)
        #expect(model.deckChoiceSyncNote(for: deck.id, on: .hosted)
            == "The saved session token could not be read. Try signing in again.")
    }
}

@MainActor
extension AppModelCampaignPromptTests {
    @Test(
        "Campaign blocks resolved decks when revalidation fails",
        .timeLimit(.minutes(1)),
        arguments: DeckChoiceValidationSource.allCases, DeckChoiceValidationFailureKind.allCases
    )
    func campaignBlocksResolvedDeckWhenValidationFails(
        source: DeckChoiceValidationSource,
        failure: DeckChoiceValidationFailureKind
    ) async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = ScriptedDeckService()
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: service, deckService: deckService
        )
        model.sessionState = .signedIn(
            profile: .hosted, compatibility: .modern(capabilities: []), user: .sample
        )
        let decks = try await prepareInvalidResolvedDeckChoice(
            model: model, service: deckService, source: source, failure: failure
        )
        let gameID = GameID(UUID())
        let ownerID = PlayerID(UUID())
        let connection = FakeGameSocketConnection()
        try installPrompt(
            chooseUpgradeDeckProjection(
                ownerID: ownerID, mode: campaignMode(canUpgradeDecks: true)
            ),
            on: model, gameID: gameID, ownerID: ownerID, connection: connection
        )
        let prompt = try #require(model.basicChoicePresentation(for: gameID))
        await service.enqueueChooseDeckResult(.success(()))
        await connection.enqueueSendResult(.success(()))

        let result = await model.upgradeCampaignDeck(
            using: decks.selected, investigatorId: "c01001", in: gameID,
            promptIdentity: prompt.identity
        )

        #expect(result == .failed(failure.message))
        #expect(await service.lastChooseDeckRequest == nil)
        #expect(await connection.sentData.isEmpty)
        #expect(model.campaignDeckSubmissions[gameID] == nil)
        #expect(model.deckChoiceSyncNote(for: decks.original.id, on: .hosted) == failure.message)
        await expectResolvedDeckWasValidated(
            decks.resolved, original: decks.original, service: deckService, source: source
        )
    }
}
