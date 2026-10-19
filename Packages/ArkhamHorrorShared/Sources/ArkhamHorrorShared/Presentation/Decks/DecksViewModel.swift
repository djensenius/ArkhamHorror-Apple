import Foundation
import Observation

struct DeckRequestContext: Sendable, Equatable {
    let token: String
    let sessionGeneration: Int
    let credentialEpoch: Int
    let globalEpoch: Int
}

/// Load/import/delete state for the signed-in deck-management screen.
@MainActor
@Observable
final class DecksViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([Deck])
        case failed(String)
    }

    enum ImportState: Equatable {
        case idle
        case importing
        case failed(String)
    }

    enum SyncState: Equatable {
        case syncing
        case succeeded(String)
        case failed(String)
    }

    typealias TokenProvider = @MainActor () async throws -> DeckRequestContext
    typealias SessionExpiredHandler = @MainActor (DeckRequestContext) async -> Void
    typealias LoadedDecksRecorder = @MainActor ([Deck]) async -> Void
    typealias ContextValidator = @MainActor (DeckRequestContext) -> Bool

    let profile: ServerProfile
    let deckService: any DeckServicing
    let deckSyncTracker: (any DeckSyncTracking)?
    let tokenProvider: TokenProvider
    let sessionExpiredHandler: SessionExpiredHandler
    let loadedDecksRecorder: LoadedDecksRecorder
    let syncedDeckRecorder: @MainActor (Deck) -> Void
    let contextValidator: ContextValidator

    var loadState: LoadState = .idle
    var importState: ImportState = .idle
    var importURL = ""
    var pendingDeletion: Deck?
    var deletingDeckIDs: Set<DeckID> = []
    var syncingDeckIDs: Set<DeckID> = []
    var deckSyncStates: [DeckID: SyncState] = [:]
    var syncAllSummary: String?
    var deletionFailure: String?
    var isSyncingAll = false
    var deletedDeckIDs: Set<DeckID> = []

    init(
        profile: ServerProfile,
        deckService: any DeckServicing,
        deckSyncTracker: (any DeckSyncTracking)? = nil,
        tokenProvider: @escaping TokenProvider,
        sessionExpiredHandler: @escaping SessionExpiredHandler = { _ in },
        loadedDecksRecorder: @escaping LoadedDecksRecorder = { _ in },
        syncedDeckRecorder: @escaping @MainActor (Deck) -> Void = { _ in },
        contextValidator: @escaping ContextValidator = { _ in true }
    ) {
        self.profile = profile
        self.deckService = deckService
        self.deckSyncTracker = deckSyncTracker
        self.tokenProvider = tokenProvider
        self.sessionExpiredHandler = sessionExpiredHandler
        self.loadedDecksRecorder = loadedDecksRecorder
        self.syncedDeckRecorder = syncedDeckRecorder
        self.contextValidator = contextValidator
    }

    var decks: [Deck] {
        if case let .loaded(decks) = loadState {
            return decks
        }
        return []
    }

    var isImporting: Bool {
        importState == .importing
    }

    var canImport: Bool {
        !importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isImporting
    }

    func load() async {
        loadState = .loading
        var requestContext: DeckRequestContext?
        do {
            let context = try await tokenProvider()
            requestContext = context
            let decks = try await deckService.listDecks(on: profile, token: context.token)
            guard contextValidator(context) else { throw GameLifecycleTokenAccessError.stale }
            let loadedDecks = decks.sortedForPresentation()
            loadState = .loaded(loadedDecks)
            await loadedDecksRecorder(loadedDecks)
        } catch is CancellationError {
            loadState = .idle
        } catch GameLifecycleTokenAccessError.stale {
            loadState = .idle
        } catch DeckServiceError.sessionExpired {
            loadState = .failed(DeckServiceError.sessionExpired.message)
            if let requestContext {
                await sessionExpiredHandler(requestContext)
            }
        } catch {
            loadState = .failed(Self.message(for: error))
        }
    }

    func importDeck() async {
        let url = importURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try DeckImportURL.parse(url)
        } catch let error as DeckImportURL.ParseError {
            importState = .failed(error.message)
            return
        } catch {
            importState = .failed(DeckImportURL.ParseError.invalid.message)
            return
        }
        importState = .importing
        var requestContext: DeckRequestContext?
        do {
            let context = try await tokenProvider()
            requestContext = context
            let deck = try await deckService.importDeck(
                from: url, on: profile, token: context.token
            )
            upsert(deck)
            importURL = ""
            importState = .idle
        } catch is CancellationError {
            importState = .idle
        } catch GameLifecycleTokenAccessError.stale {
            importState = .idle
        } catch DeckServiceError.sessionExpired {
            importState = .failed(DeckServiceError.sessionExpired.message)
            if let requestContext {
                await sessionExpiredHandler(requestContext)
            }
        } catch {
            importState = .failed(Self.message(for: error))
        }
    }

    func requestDelete(_ deck: Deck) {
        pendingDeletion = deck
    }

    func cancelDelete() {
        pendingDeletion = nil
    }

    func delete(_ deck: Deck) async {
        if pendingDeletion?.id == deck.id {
            pendingDeletion = nil
        }
        deletingDeckIDs.insert(deck.id)
        deletionFailure = nil
        var requestContext: DeckRequestContext?
        do {
            let context = try await tokenProvider()
            requestContext = context
            try await deckService.deleteDeck(deck.id, on: profile, token: context.token)
            remove(deck)
        } catch is CancellationError {
            breakDeletion(deck)
        } catch GameLifecycleTokenAccessError.stale {
            breakDeletion(deck)
        } catch DeckServiceError.sessionExpired {
            breakDeletion(deck)
            deletionFailure = DeckServiceError.sessionExpired.message
            if let requestContext {
                await sessionExpiredHandler(requestContext)
            }
        } catch {
            breakDeletion(deck)
            deletionFailure = Self.message(for: error)
        }
    }

    func deletePendingDeck() async {
        guard let deck = pendingDeletion else { return }
        await delete(deck)
    }

    func upsert(_ deck: Deck) {
        guard !deletedDeckIDs.contains(deck.id) else { return }
        var current = decks.filter { $0.id != deck.id }
        current.append(deck)
        loadState = .loaded(current.sortedForPresentation())
    }

    private func remove(_ deck: Deck) {
        deletedDeckIDs.insert(deck.id)
        let current = decks.filter { $0.id != deck.id }
        loadState = .loaded(current.sortedForPresentation())
        deletingDeckIDs.remove(deck.id)
        syncingDeckIDs.remove(deck.id)
        deckSyncStates[deck.id] = nil
    }

    private func breakDeletion(_ deck: Deck) {
        deletingDeckIDs.remove(deck.id)
    }
}
