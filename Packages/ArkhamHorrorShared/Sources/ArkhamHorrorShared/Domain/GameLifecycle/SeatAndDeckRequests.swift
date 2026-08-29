/// A request to assign (or replace) a deck for an already-claimed seat.
///
/// `investigatorId` is a plain, non-CardCode-patterned nonempty string: the contract shows
/// it both with (`c01001`) and without (`01001`) the card-code prefix depending on context.
struct ChooseDeckRequest: Sendable, Equatable, Codable {
    let investigatorId: InvestigatorCode
    let deckUrl: String?
    let deckList: DeckListInput?
}

/// A request to claim an open seat.
struct ClaimSeatRequest: Sendable, Equatable, Codable {
    let investigatorId: InvestigatorCode
}

/// The investigator card codes with unclaimed seats in a game.
typealias OpenSeats = [CardCode]
