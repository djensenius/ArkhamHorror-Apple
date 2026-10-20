@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — deck sync before choice")
struct AppModelDeckSyncChoiceTests {
    @Test("choosing a saved ArkhamDB deck syncs before sending the updated deck list")
    func chooseSavedDeckSyncsBeforeSending() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = GameLifecycleDeckService()
        let tracker = GameLifecycleDeckSyncTracker()
        let gameID = GameID(UUID())
        let deck = try deckSyncChoiceSampleDeck()
        let syncedDeck = deckSyncChoiceModifiedDeck(
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

    @Test(
        "REST ChooseDeck session expiry during sync signs out without sending",
        .timeLimit(.minutes(1))
    )
    func chooseSavedDeckSessionExpiryDuringSyncAborts() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = GameLifecycleDeckService()
        let gameID = GameID(UUID())
        let deck = try deckSyncChoiceSampleDeck()
        await deckService.enqueueSync(.failure(DeckServiceError.sessionExpired))
        await service.enqueueChooseDeckResult(.success(()))
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: service,
            deckService: deckService
        )

        model.chooseDeck(deck, investigatorId: "01001", in: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value

        #expect(await deckService.syncedIDs == [deck.id])
        #expect(await service.lastChooseDeckRequest == nil)
        guard case let .signedOut(profile, _) = model.sessionState,
              profile == .hosted
        else {
            Issue.record("Expected hosted signed-out session after sync 401")
            return
        }
    }

    @Test("sync timeout falls back to the saved deck and leaves a visible note")
    func chooseSavedDeckSyncTimeoutFallsBack() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = GameLifecycleDeckService(syncDelay: .milliseconds(100))
        let gameID = GameID(UUID())
        let deck = try deckSyncChoiceSampleDeck()
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
        let deck = try deckSyncChoiceSampleDeck()
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
        let deck = try deckSyncChoiceSampleDeck()
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
        let localDeck = deckSyncChoiceModifiedDeck(deck, url: nil, name: "Local deck")
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
}
