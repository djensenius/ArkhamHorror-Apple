@testable import ArkhamHorrorShared
import Foundation
import Testing

actor ScriptedDeckService: DeckServicing {
    private(set) var callOrder: [String] = []
    private(set) var lastImportedURL: String?
    private(set) var lastDeletedID: DeckID?
    private(set) var syncedIDs: [DeckID] = []
    private(set) var validatedDeckLists: [DeckListInput] = []

    private var listQueue: [Result<DeckListResponse, any Error>] = []
    private var isNextListGated = false
    private var listContinuation: CheckedContinuation<DeckListResponse, any Error>?
    private var listPendingWaiters: [CheckedContinuation<Void, Never>] = []
    private var importQueue: [Result<Deck, any Error>] = []
    private var deleteQueue: [Result<Void, any Error>] = []
    private var syncQueue: [Result<Deck, any Error>] = []
    private var syncResultsByID: [DeckID: Result<Deck, any Error>] = [:]
    private var syncDelaysByID: [DeckID: Duration] = [:]
    private var isSyncGated = false
    private var syncContinuations: [(
        id: DeckID,
        continuation: CheckedContinuation<Deck, any Error>
    )] = []
    private var syncWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var validateQueue: [Result<DeckValidationSuccess, any Error>] = []
    private var validationDelay: Duration?

    func gateNextList() {
        isNextListGated = true
    }

    func waitUntilListPending() async {
        guard listContinuation == nil else { return }
        await withCheckedContinuation { listPendingWaiters.append($0) }
    }

    func resumeList(with result: Result<DeckListResponse, any Error>) {
        listContinuation?.resume(with: result)
        listContinuation = nil
    }

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

    func setSyncDelay(_ delay: Duration, for id: DeckID) {
        syncDelaysByID[id] = delay
    }

    func setValidationDelay(_ delay: Duration) {
        validationDelay = delay
    }

    func enqueueValidate(_ result: Result<DeckValidationSuccess, any Error>) {
        validateQueue.append(result)
    }

    func setSyncGated(_ gated: Bool) {
        isSyncGated = gated
    }

    func waitUntilSyncPending(_ count: Int) async {
        if syncContinuations.count >= count {
            return
        }
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
        if isNextListGated {
            isNextListGated = false
            return try await withCheckedThrowingContinuation { continuation in
                listContinuation = continuation
                listPendingWaiters.forEach { $0.resume() }
                listPendingWaiters = []
            }
        }
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
        if let delay = syncDelaysByID.removeValue(forKey: id) {
            try await Task.sleep(for: delay)
        }
        if let result = syncResultsByID.removeValue(forKey: id) {
            return try result.get()
        }
        return try consume(&syncQueue)
    }

    func validateDeckList(
        _ deckList: DeckListInput, on _: ServerProfile, token _: String
    ) async throws -> DeckValidationSuccess {
        callOrder.append("validateDeckList")
        validatedDeckLists.append(deckList)
        if let validationDelay {
            try await Task.sleep(for: validationDelay)
        }
        return try consume(&validateQueue)
    }
}
