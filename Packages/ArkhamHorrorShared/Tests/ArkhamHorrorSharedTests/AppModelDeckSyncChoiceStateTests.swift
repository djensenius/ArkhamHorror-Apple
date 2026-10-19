@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
@Suite("AppModel — deck sync before choice state")
struct AppModelDeckSyncChoiceStateTests {
    @Test("session-expired sign-out clears cached deck-choice sync state")
    func sessionExpiredSignOutClearsCachedDeckChoiceSyncState() async throws {
        let service = ScriptedGameLifecycleService()
        let deck = try deckSyncChoiceSampleDeck()
        let syncedDeck = deckSyncChoiceModifiedDeck(
            deck,
            url: "https://arkhamdb.com/deck/view/stale-session-cache",
            name: "Stale synced deck",
            listName: "Stale synced list"
        )
        let tracker = GameLifecycleDeckSyncTracker()
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: service,
            deckSyncTracker: tracker
        )
        await tracker.seed(Date(), for: deck.id, deck: syncedDeck)
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
        #expect(await tracker.lastSyncedAt(for: deck.id, on: .hosted) == nil)
    }

    @Test("loaded deck lists drop differing cached synced deck bodies")
    func loadedDeckListDropsDifferingCachedSyncedDeck() async throws {
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
        let deck = try deckSyncChoiceSampleDeck()
        let syncedDeck = deckSyncChoiceModifiedDeck(
            deck,
            url: "https://arkhamdb.com/deck/view/older-synced-cache",
            name: "Older synced deck",
            listName: "Older synced list"
        )
        let loadedDeck = deckSyncChoiceModifiedDeck(
            deck,
            url: deck.url,
            name: "Freshly loaded deck",
            listName: "Freshly loaded list"
        )

        model.recordSyncedDeckForChoice(syncedDeck, on: .hosted)
        await model.recordLoadedDecksForChoice([loadedDeck], on: .hosted)

        #expect(model.deckForChoice(loadedDeck, on: .hosted) == loadedDeck)
    }

    @Test("loaded differing deck invalidates recent-sync skip before choosing")
    func loadedDifferingDeckInvalidatesRecentSyncSkipBeforeChoosing() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = GameLifecycleDeckService()
        let tracker = GameLifecycleDeckSyncTracker()
        let gameID = GameID(UUID())
        let deck = try deckSyncChoiceSampleDeck()
        let olderSyncedDeck = deckSyncChoiceModifiedDeck(
            deck,
            url: "https://arkhamdb.com/deck/view/older-choice-cache",
            name: "Older choice cache",
            listName: "Older choice list"
        )
        let loadedDeck = deckSyncChoiceModifiedDeck(
            deck,
            url: deck.url,
            name: "Freshly loaded deck",
            listName: "Freshly loaded list"
        )
        await tracker.seed(Date(), for: deck.id, deck: olderSyncedDeck)
        await deckService.enqueueSync(.success(loadedDeck))
        await service.enqueueChooseDeckResult(.success(()))
        await service.enqueueListGamesResult(.success([]))
        let model = await GameLifecycleTestModel.makeSignedIn(
            gameService: service,
            deckService: deckService,
            deckSyncTracker: tracker
        )
        model.recordSyncedDeckForChoice(olderSyncedDeck, on: .hosted)
        await model.recordLoadedDecksForChoice([loadedDeck], on: .hosted)

        model.chooseDeck(loadedDeck, investigatorId: "01001", in: gameID)
        await model.gameLifecycleActionTasks[gameID]?.value
        await model.gameListTask?.value

        #expect(await deckService.syncedIDs == [loadedDeck.id])
        let sentRequest = try #require(await service.lastChooseDeckRequest)
        #expect(sentRequest.deckUrl == loadedDeck.url)
        #expect(sentRequest.deckList == DeckListInput(loadedDeck.playableList))
    }

    @Test("recent sync skip sends the cached synced deck body")
    func chooseSavedDeckSkipUsesCachedSyncedDeck() async throws {
        let service = ScriptedGameLifecycleService()
        let deckService = GameLifecycleDeckService()
        let tracker = GameLifecycleDeckSyncTracker()
        let gameID = GameID(UUID())
        let deck = try deckSyncChoiceSampleDeck()
        let syncedDeck = deckSyncChoiceModifiedDeck(
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

    @Test("profile switch waits for deck sync tracker clear before starting the new flow")
    func profileSwitchWaitsForDeckSyncTrackerClearBeforeNewFlow() async {
        let tracker = GatedChoiceSyncTracker()
        let probe = ScriptedCapabilityProbe(.outcome(.legacyFallback))
        let model = AppModel(
            profileStore: FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile]),
            tokenStore: FakeTokenStore(),
            capabilityProbe: probe,
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: ScriptedGameLifecycleService(),
            deckService: GameLifecycleDeckService(),
            deckSyncTracker: tracker
        )
        await model.flowTask?.value
        #expect(await probe.callCount == 1)

        await tracker.blockClears()
        model.selectProfile(sampleCustomProfile)
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        #expect(await tracker.clearCallCount == 1)
        #expect(await probe.callCount == 1)

        await tracker.resumeClear()
        await model.flowTask?.value
        #expect(await probe.callCount == 2)
    }
}

actor GatedChoiceSyncTracker: DeckSyncTracking {
    private(set) var clearCallCount = 0
    private var blockClear = false
    private var clearContinuation: CheckedContinuation<Void, Never>?
    private var timestamps: [DeckID: Date] = [:]
    private var decks: [DeckID: Deck] = [:]

    func blockClears() {
        blockClear = true
    }

    func resumeClear() {
        blockClear = false
        clearContinuation?.resume()
        clearContinuation = nil
    }

    func lastSyncedAt(for deckID: DeckID, on _: ServerProfile) -> Date? {
        timestamps[deckID]
    }

    func lastSyncedDeck(for deckID: DeckID, on _: ServerProfile) -> Deck? {
        decks[deckID]
    }

    func recordSync(_ deck: Deck, on _: ServerProfile, at date: Date) {
        timestamps[deck.id] = date
        decks[deck.id] = deck
    }

    func removeSync(for deckID: DeckID, on _: ServerProfile) {
        timestamps[deckID] = nil
        decks[deckID] = nil
    }

    func clear() async {
        clearCallCount += 1
        if blockClear {
            await withCheckedContinuation { continuation in
                clearContinuation = continuation
            }
        }
        timestamps = [:]
        decks = [:]
    }
}
