import Foundation
import Observation

/// Deck-list and validation state used by the lobby choose-deck section.
@MainActor
@Observable
final class LobbyDeckSelectionViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([Deck])
        case failed(String)
    }

    enum ValidationState: Equatable {
        case pending
        case valid
        case invalid(String)
        case failed(String)
    }

    typealias TokenProvider = @MainActor () async throws -> String
    typealias SessionExpiredHandler = @MainActor () async -> Void

    private let profile: ServerProfile
    private let deckService: any DeckServicing
    private let tokenProvider: TokenProvider
    private let sessionExpiredHandler: SessionExpiredHandler

    var loadState: LoadState = .idle
    var validations: [DeckID: ValidationState] = [:]

    init(
        profile: ServerProfile,
        deckService: any DeckServicing,
        tokenProvider: @escaping TokenProvider,
        sessionExpiredHandler: @escaping SessionExpiredHandler = {}
    ) {
        self.profile = profile
        self.deckService = deckService
        self.tokenProvider = tokenProvider
        self.sessionExpiredHandler = sessionExpiredHandler
    }

    var decks: [Deck] {
        if case let .loaded(decks) = loadState {
            return decks
        }
        return []
    }

    func load(allowedInvestigatorIDs: Set<String>? = nil) async {
        guard case .loading = loadState else {
            await reload(allowedInvestigatorIDs: allowedInvestigatorIDs)
            return
        }
    }

    func reload(allowedInvestigatorIDs: Set<String>? = nil) async {
        loadState = .loading
        validations = [:]
        do {
            let token = try await tokenProvider()
            let loaded = try await deckService.listDecks(on: profile, token: token)
            let matching = loaded
                .filter { deck in
                    allowedInvestigatorIDs?.contains(deck.normalizedInvestigatorCode) ?? true
                }
                .sortedForPresentation()
            loadState = .loaded(matching)
            do {
                try await validate(matching, token: token)
            } catch is CancellationError {
                return
            }
        } catch is CancellationError {
            loadState = .idle
        } catch GameLifecycleTokenAccessError.stale {
            loadState = .idle
        } catch DeckServiceError.sessionExpired {
            loadState = .failed(DeckServiceError.sessionExpired.message)
            await sessionExpiredHandler()
        } catch {
            loadState = .failed(DecksViewModel.message(for: error))
        }
    }

    func validationState(for deck: Deck) -> ValidationState {
        validations[deck.id] ?? .pending
    }

    func claimedInvestigatorID(for deck: Deck, in investigators: [InvestigatorSummary]) -> String? {
        investigators.first { investigator in
            Deck.normalizedInvestigatorCode(investigator.id) == deck.normalizedInvestigatorCode
        }?.id
    }

    private func validate(_ decks: [Deck], token: String) async throws {
        for deck in decks {
            validations[deck.id] = .pending
            do {
                _ = try await deckService.validateDeckList(
                    DeckListInput(deck.playableList), on: profile, token: token
                )
                validations[deck.id] = .valid
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch let error as DeckServiceError {
                switch error {
                case let .validationFailed(errors):
                    validations[deck.id] = .invalid(errorMessage(for: errors))
                case .sessionExpired:
                    validations[deck.id] = .failed(error.message)
                    await sessionExpiredHandler()
                default:
                    validations[deck.id] = .failed(error.message)
                }
            } catch {
                validations[deck.id] = .failed("Deck validation failed. Try again.")
            }
        }
    }

    private func errorMessage(for errors: DeckValidationErrors) -> String {
        DeckServiceError.validationFailed(errors).message
    }
}

extension Deck {
    var normalizedInvestigatorCode: String {
        Self.normalizedInvestigatorCode(list.investigatorCode.rawValue)
    }

    static func normalizedInvestigatorCode(_ code: String) -> String {
        if code.hasPrefix("c") {
            return String(code.dropFirst())
        }
        return code
    }
}

private extension [Deck] {
    func sortedForPresentation() -> [Deck] {
        sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
