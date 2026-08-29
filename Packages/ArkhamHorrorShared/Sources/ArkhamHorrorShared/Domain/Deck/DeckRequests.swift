/// A request to save a new deck.
struct CreateDeckRequest: Sendable, Equatable, Codable {
    let deckId: String
    let deckName: String
    let deckUrl: String?
    let deckList: DeckListInput
}

/// A request to fetch and import a deck from an external URL (for example ArkhamDB).
struct FetchDeckRequest: Sendable, Equatable, Codable {
    let url: String
}
