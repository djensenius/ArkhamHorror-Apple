@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — deck sync before choice")
struct AppModelDeckSyncChoiceTests {
    private struct DeckFixture: Decodable {
        let deck: Deck
    }

    private func sampleDeck() throws -> Deck {
        let url = try #require(
            Bundle.module.url(
                forResource: "decks", withExtension: "json", subdirectory: "Fixtures/Contract"
            )
        )
        return try ContractJSON.decode(DeckFixture.self, from: Data(contentsOf: url)).deck
    }

    private func modifiedDeck(
        _ source: Deck,
        url: String?,
        name: String,
        listName: String? = nil
    ) -> Deck {
        let updatedList = DeckList(
            slots: source.list.slots,
            sideSlots: source.list.sideSlots,
            investigatorCode: source.list.investigatorCode,
            investigatorName: source.list.investigatorName,
            meta: source.list.meta,
            tabooId: source.list.tabooId,
            url: url,
            id: source.list.id,
            name: listName ?? source.list.name
        )
        return Deck(
            id: source.id,
            userId: source.userId,
            url: url,
            name: name,
            investigatorName: source.investigatorName,
            list: updatedList,
            lastUsedAt: source.lastUsedAt,
            overlay: source.overlay,
            playList: nil
        )
    }

    @Test("choosing a saved ArkhamDB deck syncs before sending the updated deck list")
    func chooseSavedDeckSyncsBeforeSending() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = GameLifecycleDeckService()
        let tracker = GameLifecycleDeckSyncTracker()
        let gameID = GameID(UUID())
        let deck = try sampleDeck()
        let syncedDeck = modifiedDeck(
            deck,
            url: "https://arkhamdb.com/deck/view/synced-lobby",
            name: "Synced deck",
            listName: "Synced list"
        )
        await deckService.enqueueSync(.success(syncedDeck))
        await service.enqueueChooseDeckResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: service,
            deckService: deckService,
            deckSyncTracker: tracker
        )

        model.chooseDeck(deck, investigatorId: "01001", in: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value
        await model.gameListTask?.value

        #expect(await deckService.syncedIDs == [deck.id])
        #expect(await tracker.records.map(\.0) == [deck.id])
        let sentRequest = try #require(await service.lastChooseDeckRequest)
        #expect(sentRequest.deckUrl == syncedDeck.url)
        #expect(sentRequest.deckList == DeckListInput(syncedDeck.playableList))
        #expect(model.deckChoiceSyncNote(for: deck.id, on: .hosted) == deckSyncSuccessMessage())
    }

    @Test("sync timeout falls back to the saved deck and leaves a visible note")
    func chooseSavedDeckSyncTimeoutFallsBack() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = GameLifecycleDeckService(syncDelay: .milliseconds(100))
        let gameID = GameID(UUID())
        let deck = try sampleDeck()
        await service.enqueueChooseDeckResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: service,
            deckService: deckService,
            deckChoiceSyncTimeout: 0.001
        )

        model.chooseDeck(deck, investigatorId: "01001", in: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value
        await model.gameListTask?.value

        #expect(await deckService.syncedIDs == [deck.id])
        let sentRequest = try #require(await service.lastChooseDeckRequest)
        #expect(sentRequest.deckList == DeckListInput(deck.playableList))
        #expect(
            model.deckChoiceSyncNote(for: deck.id, on: .hosted) == deckSyncStaleFallbackMessage()
        )
    }

    @Test("sync failure falls back to the saved deck and leaves a visible note")
    func chooseSavedDeckSyncFailureFallsBack() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = GameLifecycleDeckService()
        let gameID = GameID(UUID())
        let deck = try sampleDeck()
        await deckService.enqueueSync(.failure(DeckServiceError.operationFailed(
            DeckOperationError(errorMsg: "Could not sync deck")
        )))
        await service.enqueueChooseDeckResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: service,
            deckService: deckService
        )

        model.chooseDeck(deck, investigatorId: "01001", in: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value
        await model.gameListTask?.value

        let sentRequest = try #require(await service.lastChooseDeckRequest)
        #expect(sentRequest.deckList == DeckListInput(deck.playableList))
        #expect(
            model.deckChoiceSyncNote(for: deck.id, on: .hosted) == deckSyncStaleFallbackMessage()
        )
        #expect(model.gameLifecycleActionFailures[gameID] == nil)
    }

    @Test("recently synced decks and local decks skip the automatic sync call")
    func chooseSavedDeckSkipsRecentAndNoURLDecks() async throws {
        let recentService = ScriptedGameLifecycleService()
        let recentDeckService = GameLifecycleDeckService()
        let tracker = GameLifecycleDeckSyncTracker()
        let gameID = GameID(UUID())
        let deck = try sampleDeck()
        await tracker.seed(Date(), for: deck.id)
        await recentService.enqueueChooseDeckResult(.success(()))
        await recentService.enqueueListGamesResult(.success([]))
        let recentModel = await GameLifecycleTestModel.makeSignedIn(
            gameService: recentService,
            deckService: recentDeckService,
            deckSyncTracker: tracker
        )

        recentModel.chooseDeck(deck, investigatorId: "01001", in: gameID)
        await recentModel.gameLifecycleActionTasks[gameID]?.value
        await recentModel.gameListTask?.value
        #expect(await recentDeckService.syncedIDs.isEmpty)

        let localService = ScriptedGameLifecycleService()
        let localDeckService = GameLifecycleDeckService()
        let localDeck = modifiedDeck(deck, url: nil, name: "Local deck")
        let localGameID = GameID(UUID())
        await localService.enqueueChooseDeckResult(.success(()))
        await localService.enqueueListGamesResult(.success([]))
        let localModel = await GameLifecycleTestModel.makeSignedIn(
            gameService: localService,
            deckService: localDeckService
        )

        localModel.chooseDeck(localDeck, investigatorId: "01001", in: localGameID)
        await localModel.gameLifecycleActionTasks[localGameID]?.value
        await localModel.gameListTask?.value
        #expect(await localDeckService.syncedIDs.isEmpty)
    }

    @Test("session-expired sign-out clears cached deck-choice sync state")
    func sessionExpiredSignOutClearsCachedDeckChoiceSyncState() async throws {
        let service = ScriptedGameLifecycleService()
        let deck = try sampleDeck()
        let syncedDeck = modifiedDeck(
            deck,
            url: "https://arkhamdb.com/deck/view/stale-session-cache",
            name: "Stale synced deck",
            listName: "Stale synced list"
        )
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)
        model.recordSyncedDeckForChoice(syncedDeck, on: .hosted)
        model.deckChoiceSyncNotes[DeckChoiceSyncKey(deckID: deck.id, on: .hosted)] =
            DeckChoiceSyncNote(message: deckSyncSuccessMessage(), expiresAt: nil)
        let context = DeckRequestContext(
            token: "session-token",
            sessionGeneration: model.generation,
            credentialEpoch: model.currentCredentialEpoch(for: ServerProfile.hosted.id),
            globalEpoch: model.currentGlobalCredentialEpoch()
        )

        await model.handleDeckSessionExpired(profile: .hosted, context: context)

        #expect(model.deckForChoice(deck, on: .hosted) == deck)
        #expect(model.deckChoiceSyncNote(for: deck.id, on: .hosted) == nil)
    }

    @Test("loaded deck lists drop differing cached synced deck bodies")
    func loadedDeckListDropsDifferingCachedSyncedDeck() throws {
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: ScriptedGameLifecycleService(),
            deckService: GameLifecycleDeckService(),
            deckSyncTracker: GameLifecycleDeckSyncTracker()
        )
        let deck = try sampleDeck()
        let syncedDeck = modifiedDeck(
            deck,
            url: "https://arkhamdb.com/deck/view/older-synced-cache",
            name: "Older synced deck",
            listName: "Older synced list"
        )
        let loadedDeck = modifiedDeck(
            deck,
            url: deck.url,
            name: "Freshly loaded deck",
            listName: "Freshly loaded list"
        )

        model.recordSyncedDeckForChoice(syncedDeck, on: .hosted)
        model.recordLoadedDecksForChoice([loadedDeck], on: .hosted)

        #expect(model.deckForChoice(loadedDeck, on: .hosted) == loadedDeck)
    }

    @Test("recent sync skip sends the cached synced deck body")
    func chooseSavedDeckSkipUsesCachedSyncedDeck() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = GameLifecycleDeckService()
        let tracker = GameLifecycleDeckSyncTracker()
        let gameID = GameID(UUID())
        let deck = try sampleDeck()
        let syncedDeck = modifiedDeck(
            deck,
            url: "https://arkhamdb.com/deck/view/cached-synced",
            name: "Cached synced deck",
            listName: "Cached synced list"
        )
        await tracker.seed(Date(), for: deck.id, deck: syncedDeck)
        await service.enqueueChooseDeckResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: service,
            deckService: deckService,
            deckSyncTracker: tracker
        )

        model.chooseDeck(deck, investigatorId: "01001", in: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value
        await model.gameListTask?.value

        #expect(await deckService.syncedIDs.isEmpty)
        let sentRequest = try #require(await service.lastChooseDeckRequest)
        #expect(sentRequest.deckUrl == syncedDeck.url)
        #expect(sentRequest.deckList == DeckListInput(syncedDeck.playableList))
        #expect(model.deckForChoice(deck, on: .hosted) == syncedDeck)
    }
}
