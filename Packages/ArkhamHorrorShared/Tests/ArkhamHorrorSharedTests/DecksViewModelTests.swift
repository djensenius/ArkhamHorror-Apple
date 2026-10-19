@testable import ArkhamHorrorShared
import Foundation
import Testing

private actor ScriptedDeckService: DeckServicing {
    private(set) var callOrder: [String] = []
    private(set) var lastImportedURL: String?
    private(set) var lastDeletedID: DeckID?
    private(set) var syncedIDs: [DeckID] = []

    private var listQueue: [Result<DeckListResponse, any Error>] = []
    private var importQueue: [Result<Deck, any Error>] = []
    private var deleteQueue: [Result<Void, any Error>] = []
    private var syncQueue: [Result<Deck, any Error>] = []
    private var syncResultsByID: [DeckID: Result<Deck, any Error>] = [:]
    private var isSyncGated = false
    private var syncContinuations: [(
        id: DeckID,
        continuation: CheckedContinuation<Deck, any Error>
    )] = []
    private var syncWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var validateQueue: [Result<DeckValidationSuccess, any Error>] = []

    func enqueueList(_ result: Result<DeckListResponse, any Error>) {
        listQueue.append(result)
    }

    func enqueueImport(_ result: Result<Deck, any Error>) {
        importQueue.append(result)
    }

    func enqueueDelete(_ result: Result<Void, any Error>) {
        deleteQueue.append(result)
    }

    func enqueueSync(_ result: Result<Deck, any Error>) {
        syncQueue.append(result)
    }

    func enqueueSync(_ result: Result<Deck, any Error>, for id: DeckID) {
        syncResultsByID[id] = result
    }

    func enqueueValidate(_ result: Result<DeckValidationSuccess, any Error>) {
        validateQueue.append(result)
    }

    func setSyncGated(_ gated: Bool) {
        isSyncGated = gated
    }

    func waitUntilSyncPending(_ count: Int) async {
        if syncContinuations.count >= count { return }
        await withCheckedContinuation { syncWaiters.append((count, $0)) }
    }

    func resumeSync(for id: DeckID, with result: Result<Deck, any Error>) {
        guard let index = syncContinuations.firstIndex(where: { $0.id == id }) else { return }
        let continuation = syncContinuations.remove(at: index).continuation
        switch result {
        case let .success(deck): continuation.resume(returning: deck)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    private func notifySyncWaiters() {
        syncWaiters.removeAll { threshold, continuation in
            guard syncContinuations.count >= threshold else { return false }
            continuation.resume()
            return true
        }
    }

    private func consume<T>(_ queue: inout [Result<T, any Error>]) throws -> T {
        guard !queue.isEmpty else { throw TestFailure() }
        return try queue.removeFirst().get()
    }

    func listDecks(on _: ServerProfile, token _: String) async throws -> DeckListResponse {
        callOrder.append("listDecks")
        return try consume(&listQueue)
    }

    func fetchDeckList(
        _: FetchDeckRequest, on _: ServerProfile, token _: String
    ) async throws -> DeckList {
        throw TestFailure()
    }

    func createDeck(
        _: CreateDeckRequest, on _: ServerProfile, token _: String
    ) async throws -> Deck {
        throw TestFailure()
    }

    func importDeck(from url: String, on _: ServerProfile, token _: String) async throws -> Deck {
        callOrder.append("importDeck")
        lastImportedURL = url
        return try consume(&importQueue)
    }

    func deleteDeck(_ id: DeckID, on _: ServerProfile, token _: String) async throws {
        callOrder.append("deleteDeck")
        lastDeletedID = id
        try consume(&deleteQueue)
    }

    func syncDeck(
        _ id: DeckID,
        on _: ServerProfile,
        token _: String,
        timeout _: TimeInterval
    ) async throws -> Deck {
        callOrder.append("syncDeck")
        syncedIDs.append(id)
        if isSyncGated {
            return try await withCheckedThrowingContinuation { continuation in
                syncContinuations.append((id, continuation))
                notifySyncWaiters()
            }
        }
        if let result = syncResultsByID.removeValue(forKey: id) {
            return try result.get()
        }
        return try consume(&syncQueue)
    }

    func validateDeckList(
        _: DeckListInput, on _: ServerProfile, token _: String
    ) async throws -> DeckValidationSuccess {
        callOrder.append("validateDeckList")
        return try consume(&validateQueue)
    }
}

private actor RecordingDeckSyncTracker: DeckSyncTracking {
    private(set) var records: [(DeckID, Date)] = []
    private var decks: [DeckID: Deck] = [:]

    func lastSyncedAt(for _: DeckID, on _: ServerProfile) -> Date? {
        nil
    }

    func lastSyncedDeck(for deckID: DeckID, on _: ServerProfile) -> Deck? {
        decks[deckID]
    }

    func recordSync(_ deck: Deck, on _: ServerProfile, at date: Date) {
        records.append((deck.id, date))
        decks[deck.id] = deck
    }

    func clear() {
        records = []
        decks = [:]
    }
}

private struct DecksViewModelFixture: Decodable {
    let deck: Deck
    let operationError: DeckOperationError
    let validationErrors: DeckValidationErrors
}

@MainActor
@Suite("DecksViewModel")
struct DecksViewModelTests {
    private func loadFixture() throws -> DecksViewModelFixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "decks",
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try ContractJSON.decode(DecksViewModelFixture.self, from: Data(contentsOf: url))
    }

    private func makeModel(
        service: ScriptedDeckService,
        tracker: (any DeckSyncTracking)? = nil,
        tokenProvider: @escaping DecksViewModel.TokenProvider = {
            DeckRequestContext(
                token: "token", sessionGeneration: 0, credentialEpoch: 0, globalEpoch: 0
            )
        },
        sessionExpiredHandler: @escaping DecksViewModel.SessionExpiredHandler = { _ in }
    ) -> DecksViewModel {
        DecksViewModel(
            profile: .hosted,
            deckService: service,
            deckSyncTracker: tracker,
            tokenProvider: tokenProvider,
            sessionExpiredHandler: sessionExpiredHandler
        )
    }

    private func deck(
        _ source: Deck,
        id: UUID = UUID(),
        url: String?,
        name: String
    ) -> Deck {
        Deck(
            id: DeckID(id),
            userId: source.userId,
            url: url,
            name: name,
            investigatorName: source.investigatorName,
            list: source.list,
            lastUsedAt: source.lastUsedAt,
            overlay: source.overlay,
            playList: source.playList
        )
    }

    @Test("load moves through loaded empty and failed states")
    func loadStates() async {
        let service = ScriptedDeckService()
        await service.enqueueList(.success([]))
        let model = makeModel(service: service)

        await model.load()
        #expect(model.loadState == .loaded([]))

        await service.enqueueList(.failure(DeckServiceError.unexpectedStatus(500)))
        await model.load()
        #expect(model.loadState == .failed(DeckServiceError.unexpectedStatus(500).message))
    }

    @Test("blank import URL fails before network and successful import appends the deck")
    func importStates() async throws {
        let fixture = try loadFixture()
        let service = ScriptedDeckService()
        let model = makeModel(service: service)

        await model.importDeck()
        #expect(
            model.importState == .failed(DeckImportURL.ParseError.invalid.message)
        )
        #expect(await service.callOrder.isEmpty)

        model.importURL = " https://arkhamdb.com/decklist/view/4242 "
        await service.enqueueImport(.success(fixture.deck))
        await model.importDeck()

        #expect(model.importState == .idle)
        #expect(model.decks == [fixture.deck])
        #expect(await service.lastImportedURL == "https://arkhamdb.com/decklist/view/4242")
    }

    @Test("import surfaces fetch operation and validation messages clearly")
    func importErrorMessages() async throws {
        let fixture = try loadFixture()
        let service = ScriptedDeckService()
        let model = makeModel(service: service)

        model.importURL = "https://arkhamdb.com/decklist/view/4242"
        await service.enqueueImport(
            .failure(DeckServiceError.operationFailed(fixture.operationError))
        )
        await model.importDeck()
        #expect(model.importState == .failed("Could not sync deck"))

        await service.enqueueImport(
            .failure(DeckServiceError.validationFailed(fixture.validationErrors))
        )
        await model.importDeck()
        #expect(model.importState == .failed("Unsupported card c99999"))
    }

    @Test("delete asks for confirmation then removes the deck through the view-called API")
    func deleteStates() async throws {
        let fixture = try loadFixture()
        let service = ScriptedDeckService()
        let model = makeModel(service: service)
        await service.enqueueList(.success([fixture.deck]))
        await model.load()

        model.requestDelete(fixture.deck)
        #expect(model.pendingDeletion == fixture.deck)
        await service.enqueueDelete(.success(()))
        await model.delete(fixture.deck)

        #expect(model.pendingDeletion == nil)
        #expect(model.decks.isEmpty)
        #expect(await service.lastDeletedID == fixture.deck.id)
    }

    @Test("401 deck failures invoke the session-expired handler")
    func sessionExpiredHandlerRuns() async {
        let service = ScriptedDeckService()
        await service.enqueueList(.failure(DeckServiceError.sessionExpired))
        var expirations = 0
        let model = makeModel(
            service: service,
            sessionExpiredHandler: { _ in expirations += 1 }
        )

        await model.load()

        #expect(
            model.loadState == DecksViewModel.LoadState.failed(
                DeckServiceError.sessionExpired.message
            )
        )
        #expect(expirations == 1)
    }

    @Test("stale token access is treated like cancellation without surfacing an error")
    func staleTokenIsSilent() async {
        let model = makeModel(
            service: ScriptedDeckService(),
            tokenProvider: { throw GameLifecycleTokenAccessError.stale }
        )

        model.importURL = "https://arkhamdb.com/decklist/view/4242"
        await model.importDeck()

        #expect(model.importState == .idle)
    }

    @Test("delete failure leaves the loaded deck list visible and shows an inline error")
    func deleteFailureKeepsLoadedList() async throws {
        let fixture = try loadFixture()
        let service = ScriptedDeckService()
        let model = makeModel(service: service)
        await service.enqueueList(.success([fixture.deck]))
        await model.load()

        await service.enqueueDelete(.failure(DeckServiceError.unexpectedStatus(500)))
        await model.delete(fixture.deck)

        #expect(model.decks == [fixture.deck])
        #expect(model.loadState == .loaded([fixture.deck]))
        #expect(model.deletionFailure == DeckServiceError.unexpectedStatus(500).message)
    }

    @Test("per-deck sync upserts successes and surfaces 400 failures")
    func syncDeckStates() async throws {
        let fixture = try loadFixture()
        let service = ScriptedDeckService()
        let tracker = RecordingDeckSyncTracker()
        let model = makeModel(service: service, tracker: tracker)
        await service.enqueueList(.success([fixture.deck]))
        await model.load()

        let syncedDeck = deck(
            fixture.deck,
            id: fixture.deck.id.rawValue,
            url: fixture.deck.url,
            name: "Synced deck"
        )
        await service.enqueueSync(.success(syncedDeck))
        await model.sync(fixture.deck)

        #expect(model.decks == [syncedDeck])
        #expect(model.syncState(for: syncedDeck) == .succeeded(deckSyncSuccessMessage()))
        #expect(await service.syncedIDs == [fixture.deck.id])
        #expect(await tracker.records.map(\.0) == [fixture.deck.id])

        await service.enqueueSync(.failure(
            DeckServiceError.operationFailed(fixture.operationError)
        ))
        await model.sync(syncedDeck)
        #expect(model.syncState(for: syncedDeck) == .failed("Could not sync deck"))
    }

    @Test("deck without an ArkhamDB URL does not offer a sync call")
    func syncSkipsDeckWithoutURL() async throws {
        let fixture = try loadFixture()
        let localDeck = deck(fixture.deck, url: nil, name: "Local deck")
        let service = ScriptedDeckService()
        let model = makeModel(service: service)

        await model.sync(localDeck)

        #expect(await service.syncedIDs.isEmpty)
        #expect(model.syncState(for: localDeck) == nil)
    }

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

        #expect(Set(await service.syncedIDs) == Set([first.id, third.id]))
        #expect(model.decks.map(\.name) == ["A synced", "B", "C"])
        #expect(model.syncState(for: syncedFirst) == .succeeded(deckSyncSuccessMessage()))
        #expect(
            model.syncState(for: third)
                == .failed(DeckServiceError.unexpectedStatus(500).message)
        )
        #expect(model.syncState(for: second) == nil)
        #expect(model.syncAllSummary == "Synced 1 of 2 ArkhamDB decks. 1 failed.")
    }

    @Test("refresh and sync handles session expiry and cancellation without counting cancels as failures")
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
        await service.enqueueSync(.failure(DeckServiceError.sessionExpired), for: sessionExpiredDeck.id)
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
