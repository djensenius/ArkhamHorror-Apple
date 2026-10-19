@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
extension DecksViewModelTests {
    @Test(
        "cancelled refresh and sync clears all busy rows and permits another refresh",
        .timeLimit(.minutes(1))
    )
    func cancelledRefreshAndSyncClearsBusyStateAndPermitsRefresh() async throws {
        let fixture = try loadFixture()
        let first = deck(fixture.deck, url: fixture.deck.url, name: "A first")
        let second = deck(fixture.deck, url: fixture.deck.url, name: "B second")
        let service = ScriptedDeckService()
        await service.setSyncGated(true)
        await service.enqueueList(.success([first, second]))
        let model = makeModel(service: service)
        let task = Task { await model.refreshAndSync() }
        await service.waitUntilSyncPending(2)
        #expect(model.syncingDeckIDs == Set([first.id, second.id]))

        task.cancel()
        await service.resumeSync(for: first.id, with: .success(first))
        await service.resumeSync(for: second.id, with: .failure(CancellationError()))
        await task.value

        #expect(model.syncingDeckIDs.isEmpty)
        #expect(!model.deckSyncStates.values.contains(.syncing))
        #expect(!model.isSyncingAll)
        await service.enqueueList(.success([]))
        await model.refreshAndSync()
        #expect(await service.callOrder.filter { $0 == "listDecks" }.count == 2)
    }

    @Test("refresh and sync aggregates per-deck results", .timeLimit(.minutes(1)))
    func refreshAndSyncAggregatesResults() async throws {
        let fixture = try loadFixture()
        let first = try deck(
            fixture.deck,
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000101")),
            url: fixture.deck.url,
            name: "A"
        )
        let second = try deck(
            fixture.deck,
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000102")),
            url: nil,
            name: "B"
        )
        let third = try deck(
            fixture.deck,
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000103")),
            url: fixture.deck.url,
            name: "C"
        )
        let syncedFirst = deck(first, id: first.id.rawValue, url: first.url, name: "A synced")
        let service = ScriptedDeckService()
        let model = makeModel(service: service)
        await service.enqueueList(.success([third, second, first]))
        await service.enqueueSync(.success(syncedFirst), for: first.id)
        await service.enqueueSync(
            .failure(DeckServiceError.unexpectedStatus(500)),
            for: third.id
        )

        await model.refreshAndSync()

        #expect(await Set(service.syncedIDs) == Set([first.id, third.id]))
        #expect(model.decks.map(\.name) == ["A synced", "B", "C"])
        #expect(model.syncState(for: syncedFirst) == .succeeded(deckSyncSuccessMessage()))
        #expect(
            model.syncState(for: third)
                == .failed(DeckServiceError.unexpectedStatus(500).message)
        )
        #expect(model.syncState(for: second) == nil)
        #expect(model.syncAllSummary == "Synced 1 of 2 decks with a deck source. 1 failed.")
    }

    @Test("refresh and sync handles expiry and cancellation separately", .timeLimit(.minutes(1)))
    func refreshAndSyncSessionExpiryAndCancellation() async throws {
        let fixture = try loadFixture()
        let sessionExpiredDeck = deck(fixture.deck, url: fixture.deck.url, name: "Expired")
        let cancelledDeck = deck(fixture.deck, url: fixture.deck.url, name: "Cancelled")
        let service = ScriptedDeckService()
        var expirations = 0
        let model = makeModel(
            service: service,
            sessionExpiredHandler: { _ in expirations += 1 }
        )
        await service.enqueueList(.success([sessionExpiredDeck, cancelledDeck]))
        await service.enqueueSync(
            .failure(DeckServiceError.sessionExpired),
            for: sessionExpiredDeck.id
        )
        await service.enqueueSync(.failure(CancellationError()), for: cancelledDeck.id)

        await model.refreshAndSync()

        #expect(expirations == 1)
        #expect(
            model.syncState(for: sessionExpiredDeck)
                == .failed(DeckServiceError.sessionExpired.message)
        )
        #expect(model.syncState(for: cancelledDeck) == nil)
        #expect(model.syncAllSummary == "Synced 0 of 2 decks with a deck source. 1 failed.")
    }

    @Test("bulk sync calls each syncable deck ID only once", .timeLimit(.minutes(1)))
    func bulkSyncDeduplicatesSyncableDeckIDs() async throws {
        let fixture = try loadFixture()
        let first = deck(fixture.deck, url: fixture.deck.url, name: "A first")
        let second = deck(fixture.deck, url: fixture.deck.url, name: "B second")
        let local = deck(fixture.deck, url: nil, name: "C local")
        let service = ScriptedDeckService()
        await service.enqueueList(.success([first, first, second, local, second]))
        await service.enqueueSync(.success(first), for: first.id)
        await service.enqueueSync(.success(second), for: second.id)
        let model = makeModel(service: service)

        await model.refreshAndSync()

        let syncedIDs = await service.syncedIDs
        #expect(syncedIDs.count == 2)
        #expect(Set(syncedIDs) == Set([first.id, second.id]))
        #expect(model.syncAllSummary == "Synced 2 of 2 decks with a deck source. 0 failed.")
    }

    @Test("sync-all stops queueing after the first 401", .timeLimit(.minutes(1)))
    func syncAllStopsQueueingAfterFirstSessionExpired() async throws {
        let fixture = try loadFixture()
        let first = deck(fixture.deck, url: fixture.deck.url, name: "A first")
        let second = deck(fixture.deck, url: fixture.deck.url, name: "B second")
        let third = deck(fixture.deck, url: fixture.deck.url, name: "C third")
        let fourth = deck(fixture.deck, url: fixture.deck.url, name: "D fourth")
        let service = ScriptedDeckService()
        await service.enqueueList(.success([first, second, third, fourth]))
        await service.enqueueSync(.failure(DeckServiceError.sessionExpired), for: first.id)
        await service.enqueueSync(.success(second), for: second.id)
        await service.enqueueSync(.success(third), for: third.id)
        await service.enqueueSync(.success(fourth), for: fourth.id)
        await service.setSyncDelay(.milliseconds(100), for: second.id)
        await service.setSyncDelay(.milliseconds(100), for: third.id)
        var expirations = 0
        let model = makeModel(
            service: service,
            sessionExpiredHandler: { _ in expirations += 1 }
        )

        await model.refreshAndSync()

        let syncedIDs = await service.syncedIDs
        #expect(syncedIDs.contains(first.id))
        #expect(syncedIDs.contains(second.id))
        #expect(syncedIDs.contains(third.id))
        #expect(!syncedIDs.contains(fourth.id))
        #expect(expirations == 1)
    }

    @Test("refresh and sync ignores re-entry while syncs are active", .timeLimit(.minutes(1)))
    func refreshAndSyncIgnoresReentry() async throws {
        let fixture = try loadFixture()
        let service = ScriptedDeckService()
        await service.setSyncGated(true)
        let model = makeModel(service: service)
        await service.enqueueList(.success([fixture.deck]))
        let firstRun = Task { await model.refreshAndSync() }
        await service.waitUntilSyncPending(1)

        await model.refreshAndSync()

        #expect(await service.callOrder.filter { $0 == "listDecks" }.count == 1)
        #expect(await service.syncedIDs == [fixture.deck.id])
        await service.resumeSync(for: fixture.deck.id, with: .success(fixture.deck))
        await firstRun.value
        #expect(model.syncAllSummary == "Synced 1 of 1 decks with a deck source. 0 failed.")
    }

    @Test("refresh and sync is ignored while an individual sync is active", .timeLimit(.minutes(1)))
    func refreshAndSyncIgnoresActiveIndividualSync() async throws {
        let fixture = try loadFixture()
        let service = ScriptedDeckService()
        await service.setSyncGated(true)
        let model = makeModel(service: service)
        await service.enqueueList(.success([fixture.deck]))
        await model.load()
        let syncTask = Task { await model.sync(fixture.deck) }
        await service.waitUntilSyncPending(1)

        await model.refreshAndSync()

        #expect(await service.callOrder.filter { $0 == "listDecks" }.count == 1)
        #expect(await service.syncedIDs == [fixture.deck.id])
        await service.resumeSync(for: fixture.deck.id, with: .success(fixture.deck))
        await syncTask.value
    }

    @Test(
        "manual sync is ignored during bulk sync and duplicate row syncs are deduped",
        .timeLimit(.minutes(1))
    )
    func manualSyncIgnoresBulkAndDuplicateActiveIDs() async throws {
        let fixture = try loadFixture()
        let first = deck(fixture.deck, url: fixture.deck.url, name: "A first")
        let second = deck(fixture.deck, url: fixture.deck.url, name: "B second")
        let service = ScriptedDeckService()
        await service.setSyncGated(true)
        await service.enqueueList(.success([first, second]))
        let model = makeModel(service: service)

        let bulkTask = Task { await model.refreshAndSync() }
        await service.waitUntilSyncPending(2)
        await model.sync(second)
        #expect(await service.syncedIDs == [first.id, second.id])
        await service.resumeSync(for: first.id, with: .success(first))
        await service.resumeSync(for: second.id, with: .success(second))
        await bulkTask.value

        let rowTask = Task { await model.sync(first) }
        await service.waitUntilSyncPending(1)
        await model.sync(first)
        #expect(await service.syncedIDs.filter { $0 == first.id }.count == 2)
        await service.resumeSync(for: first.id, with: .success(first))
        await rowTask.value
    }

    @Test(
        "bulk sync discards successes that complete after session expiry",
        .timeLimit(.minutes(1))
    )
    func bulkSyncDiscardsBufferedSuccessesAfterSessionExpiry() async throws {
        let fixture = try loadFixture()
        let expired = deck(fixture.deck, url: fixture.deck.url, name: "A expired")
        let successful = deck(fixture.deck, url: fixture.deck.url, name: "B success")
        let syncedSuccess = deck(
            successful,
            id: successful.id.rawValue,
            url: successful.url,
            name: "B stale success"
        )
        let service = ScriptedDeckService()
        let tracker = RecordingDeckSyncTracker()
        await service.setSyncGated(true)
        await service.enqueueList(.success([expired, successful]))
        var expirations = 0
        let model = makeModel(
            service: service,
            tracker: tracker,
            sessionExpiredHandler: { _ in expirations += 1 }
        )
        let bulkTask = Task { await model.refreshAndSync() }
        await service.waitUntilSyncPending(2)

        await service.resumeSync(for: expired.id, with: .failure(DeckServiceError.sessionExpired))
        while expirations == 0 {
            await Task.yield()
        }
        await service.resumeSync(for: successful.id, with: .success(syncedSuccess))
        await bulkTask.value

        #expect(expirations == 1)
        #expect(model.decks == [expired, successful])
        #expect(await tracker.records.isEmpty)
    }

    @Test(
        "deleting a deck while sync is active prevents a stale sync from resurrecting it",
        .timeLimit(.minutes(1))
    )
    func deleteDuringSyncPreventsResurrection() async throws {
        let fixture = try loadFixture()
        let service = ScriptedDeckService()
        await service.setSyncGated(true)
        let model = makeModel(service: service)
        await service.enqueueList(.success([fixture.deck]))
        await model.load()
        let syncTask = Task { await model.sync(fixture.deck) }
        await service.waitUntilSyncPending(1)
        await service.enqueueDelete(.success(()))

        await model.delete(fixture.deck)
        await service.resumeSync(for: fixture.deck.id, with: .success(fixture.deck))
        await syncTask.value

        #expect(model.decks.isEmpty)
        #expect(model.syncState(for: fixture.deck) == nil)
    }
}
