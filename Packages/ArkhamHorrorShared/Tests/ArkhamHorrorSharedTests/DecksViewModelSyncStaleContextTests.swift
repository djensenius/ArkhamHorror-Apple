@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
extension DecksViewModelTests {
    @Test("row sync rejects stale context before recording", .timeLimit(.minutes(1)))
    func rowSyncRejectsStaleContextBeforeRecording() async throws {
        let fixture = try loadFixture()
        let first = deck(fixture.deck, url: fixture.deck.url, name: "A first")
        let second = deck(fixture.deck, url: fixture.deck.url, name: "B second")
        let service = ScriptedDeckService()
        let tracker = RecordingDeckSyncTracker()
        await service.setSyncGated(true)
        await service.enqueueList(.success([first, second]))
        var isCurrentContext = true
        var publishedIDs: [DeckID] = []
        let model = makeModel(
            service: service,
            tracker: tracker,
            syncedDeckRecorder: { publishedIDs.append($0.id) },
            contextValidator: { _ in isCurrentContext }
        )
        await model.load()
        let task = Task { await model.sync(first) }
        await service.waitUntilSyncPending(1)
        let startedIDs = await service.syncedIDs

        isCurrentContext = false
        let synced = deck(first, id: first.id.rawValue, url: first.url, name: "Stale success")
        await service.resumeSync(for: first.id, with: .success(synced))
        await task.value

        #expect(model.decks == [first, second])
        #expect(model.syncState(for: first) == nil)
        #expect(publishedIDs.isEmpty)
        #expect(await service.syncedIDs == startedIDs)
        #expect(await tracker.recordedIDs.isEmpty)
    }

    @Test("row sync rechecks context after awaiting tracker write", .timeLimit(.minutes(1)))
    func rowSyncRejectsStaleContextAfterRecording() async throws {
        let fixture = try loadFixture()
        let first = deck(fixture.deck, url: fixture.deck.url, name: "A first")
        let second = deck(fixture.deck, url: fixture.deck.url, name: "B second")
        let service = ScriptedDeckService()
        let tracker = RecordingDeckSyncTracker()
        await tracker.setRecordGated(true)
        await service.enqueueList(.success([first, second]))
        let synced = deck(first, id: first.id.rawValue, url: first.url, name: "Stale success")
        await service.enqueueSync(.success(synced))
        var isCurrentContext = true
        var publishedIDs: [DeckID] = []
        let model = makeModel(
            service: service,
            tracker: tracker,
            syncedDeckRecorder: { publishedIDs.append($0.id) },
            contextValidator: { _ in isCurrentContext }
        )
        await model.load()
        let task = Task { await model.sync(first) }
        await tracker.waitUntilRecordPending()
        let startedIDs = await service.syncedIDs

        isCurrentContext = false
        await tracker.resumeRecord()
        await task.value

        #expect(model.decks == [first, second])
        #expect(model.syncState(for: first) == nil)
        #expect(publishedIDs.isEmpty)
        #expect(await service.syncedIDs == startedIDs)
        #expect(await tracker.recordedIDs == [first.id])
        #expect(await tracker.records.isEmpty)
    }

    @Test(
        "bulk sync rejects stale context before recording or queueing more",
        .timeLimit(.minutes(1))
    )
    func bulkSyncRejectsStaleContextBeforeRecordingOrQueueingMore() async throws {
        let fixture = try loadFixture()
        let decks = ["A", "B", "C", "D"].map {
            deck(fixture.deck, url: fixture.deck.url, name: $0)
        }
        let service = ScriptedDeckService()
        let tracker = RecordingDeckSyncTracker()
        await service.setSyncGated(true)
        await service.enqueueList(.success(decks))
        var isCurrentContext = true
        var publishedIDs: [DeckID] = []
        let model = makeModel(
            service: service,
            tracker: tracker,
            syncedDeckRecorder: { publishedIDs.append($0.id) },
            contextValidator: { _ in isCurrentContext }
        )
        let task = Task { await model.refreshAndSync() }
        await service.waitUntilSyncPending(3)
        let startedIDs = await service.syncedIDs
        #expect(Set(startedIDs) == Set(decks.prefix(3).map(\.id)))

        isCurrentContext = false
        for deck in decks.prefix(3) {
            await service.resumeSync(for: deck.id, with: .success(deck))
        }
        await task.value

        #expect(model.loadState == .idle)
        #expect(model.syncAllSummary == nil)
        #expect(model.deckSyncStates.isEmpty)
        #expect(publishedIDs.isEmpty)
        #expect(await service.syncedIDs == startedIDs)
        #expect(await tracker.recordedIDs.isEmpty)
    }

    @Test("bulk sync rechecks context after awaiting tracker write", .timeLimit(.minutes(1)))
    func bulkSyncRejectsStaleContextAfterRecording() async throws {
        let fixture = try loadFixture()
        let decks = ["A", "B", "C", "D"].map {
            deck(fixture.deck, url: fixture.deck.url, name: $0)
        }
        let service = ScriptedDeckService()
        let tracker = RecordingDeckSyncTracker()
        await service.setSyncGated(true)
        await tracker.setRecordGated(true)
        await service.enqueueList(.success(decks))
        var isCurrentContext = true
        var publishedIDs: [DeckID] = []
        let model = makeModel(
            service: service,
            tracker: tracker,
            syncedDeckRecorder: { publishedIDs.append($0.id) },
            contextValidator: { _ in isCurrentContext }
        )
        let task = Task { await model.refreshAndSync() }
        await service.waitUntilSyncPending(3)
        let startedIDs = await service.syncedIDs
        let synced = deck(
            decks[0], id: decks[0].id.rawValue, url: decks[0].url, name: "Stale success"
        )
        await service.resumeSync(for: decks[0].id, with: .success(synced))
        await tracker.waitUntilRecordPending()

        isCurrentContext = false
        await tracker.resumeRecord()
        for deck in decks[1 ..< 3] {
            await service.resumeSync(for: deck.id, with: .success(deck))
        }
        await task.value

        #expect(model.loadState == .idle)
        #expect(model.syncAllSummary == nil)
        #expect(model.deckSyncStates.isEmpty)
        #expect(publishedIDs.isEmpty)
        #expect(await service.syncedIDs == startedIDs)
        #expect(await tracker.recordedIDs == [decks[0].id])
        #expect(await tracker.records.isEmpty)
    }
}
