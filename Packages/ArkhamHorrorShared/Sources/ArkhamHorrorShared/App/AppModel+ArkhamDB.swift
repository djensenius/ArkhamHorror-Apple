import Foundation

extension AppModel {
    func supportsArkhamDB(on profile: ServerProfile) -> Bool {
        guard case let .signedIn(currentProfile, compatibility, _) = sessionState,
              currentProfile == profile else { return false }
        return compatibility.supportsArkhamDBAccountLinking
    }

    func deckService(on profile: ServerProfile) -> any DeckServicing {
        guard supportsArkhamDB(on: profile) else { return deckService }
        return ArkhamDBSyncDeckService(base: deckService, arkhamDB: arkhamDBService)
    }
}

/// The server owns link mappings and falls back to public sync for unmapped decks.
/// Apply this adapter only after capability negotiation; old servers keep their route.
struct ArkhamDBSyncDeckService: DeckServicing {
    let base: any DeckServicing
    let arkhamDB: ArkhamDBService

    func listDecks(on profile: ServerProfile, token: String) async throws -> DeckListResponse {
        try await base.listDecks(on: profile, token: token)
    }

    func fetchDeckList(
        _ request: FetchDeckRequest, on profile: ServerProfile, token: String
    ) async throws -> DeckList {
        try await base.fetchDeckList(request, on: profile, token: token)
    }

    func createDeck(
        _ request: CreateDeckRequest, on profile: ServerProfile, token: String
    ) async throws -> Deck {
        try await base.createDeck(request, on: profile, token: token)
    }

    func importDeck(
        from url: String,
        on profile: ServerProfile,
        token: String
    ) async throws -> Deck {
        try await base.importDeck(from: url, on: profile, token: token)
    }

    func deleteDeck(_ id: DeckID, on profile: ServerProfile, token: String) async throws {
        try await base.deleteDeck(id, on: profile, token: token)
    }

    func syncDeck(
        _ id: DeckID, on profile: ServerProfile, token: String, timeout: TimeInterval
    ) async throws -> Deck {
        try await arkhamDB.syncDeck(id, on: profile, token: token, timeout: timeout)
    }

    func validateDeckList(
        _ deckList: DeckListInput, on profile: ServerProfile, token: String
    ) async throws -> DeckValidationSuccess {
        try await base.validateDeckList(deckList, on: profile, token: token)
    }
}
