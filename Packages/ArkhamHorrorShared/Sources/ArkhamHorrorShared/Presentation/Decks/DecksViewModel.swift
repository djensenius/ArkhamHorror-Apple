import Foundation
import Observation

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

    typealias TokenProvider = @MainActor () async throws -> String

    private let profile: ServerProfile
    private let deckService: any DeckServicing
    private let tokenProvider: TokenProvider

    var loadState: LoadState = .idle
    var importState: ImportState = .idle
    var importURL = ""
    var pendingDeletion: Deck?
    var deletingDeckIDs: Set<DeckID> = []

    init(
        profile: ServerProfile,
        deckService: any DeckServicing,
        tokenProvider: @escaping TokenProvider
    ) {
        self.profile = profile
        self.deckService = deckService
        self.tokenProvider = tokenProvider
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
        do {
            let token = try await tokenProvider()
            let decks = try await deckService.listDecks(on: profile, token: token)
            loadState = .loaded(decks.sortedForPresentation())
        } catch is CancellationError {
            loadState = .idle
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
        do {
            let token = try await tokenProvider()
            let deck = try await deckService.importDeck(from: url, on: profile, token: token)
            upsert(deck)
            importURL = ""
            importState = .idle
        } catch is CancellationError {
            importState = .idle
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

    func deletePendingDeck() async {
        guard let deck = pendingDeletion else { return }
        pendingDeletion = nil
        deletingDeckIDs.insert(deck.id)
        do {
            let token = try await tokenProvider()
            try await deckService.deleteDeck(deck.id, on: profile, token: token)
            remove(deck)
        } catch is CancellationError {
            breakDeletion(deck)
        } catch {
            breakDeletion(deck)
            loadState = .failed(Self.message(for: error))
        }
    }

    private func upsert(_ deck: Deck) {
        var current = decks.filter { $0.id != deck.id }
        current.append(deck)
        loadState = .loaded(current.sortedForPresentation())
    }

    private func remove(_ deck: Deck) {
        let current = decks.filter { $0.id != deck.id }
        loadState = .loaded(current.sortedForPresentation())
        deletingDeckIDs.remove(deck.id)
    }

    private func breakDeletion(_ deck: Deck) {
        deletingDeckIDs.remove(deck.id)
    }

    static func message(for error: any Error) -> String {
        if let deckError = error as? DeckServiceError {
            return deckError.message
        }
        if let gameError = error as? GameLifecycleTokenAccessError {
            switch gameError {
            case .stale:
                return "The signed-in session changed. Try again."
            case .noToken:
                return "Your session is no longer available. Sign in again to manage decks."
            case .tokenStore:
                return "The saved session token could not be read. Try signing in again."
            }
        }
        return "The deck operation failed. Try again."
    }
}

private extension [Deck] {
    func sortedForPresentation() -> [Deck] {
        sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
