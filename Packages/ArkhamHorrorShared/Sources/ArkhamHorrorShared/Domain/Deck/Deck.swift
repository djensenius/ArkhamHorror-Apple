/// A saved deck, as returned by the deck endpoints once a ``DeckListInput`` has been
/// normalized and persisted.
struct Deck: Sendable, Equatable, Codable {
    let id: DeckID
    let userId: Int
    let url: String?
    let name: String
    let investigatorName: String
    let list: DeckList
}

/// A list of saved decks.
typealias DeckListResponse = [Deck]
