@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
extension DecksViewModelTests {
    @Test("refresh and sync aggregates per-deck results")
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
        #expect(model.syncAllSummary == "Synced 1 of 2 ArkhamDB decks. 1 failed.")
    }

    @Test("refresh and sync handles expiry and cancellation separately")
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
        #expect(model.syncAllSummary == "Synced 0 of 2 ArkhamDB decks. 1 failed.")
    }

    @Test("refresh and sync ignores re-entry while syncs are active")
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
        #expect(model.syncAllSummary == "Synced 1 of 1 ArkhamDB decks. 0 failed.")
    }

    @Test("deleting a deck while sync is active prevents a stale sync from resurrecting it")
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
