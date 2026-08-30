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

extension InvestigatorCode {
    /// Converts a `GET .../open-seats` result (a `c`-prefixed ``CardCode``, for example
    /// `c01001`) into the shape ``ClaimSeatRequest/investigatorId`` and
    /// ``ChooseDeckRequest/investigatorId`` expect.
    ///
    /// Never strips the prefix: the backend's own normalization
    /// (`Api.Handler.Arkham.Game.Debug.normalizeJsonInvestigatorId`) adds a `c` prefix
    /// only when one is *missing* and otherwise passes an already-prefixed identifier
    /// through unchanged, so forwarding the open-seat code's exact wire text here is
    /// exactly as valid as stripping it first would be -- and avoids this client
    /// re-deriving a normalization rule the backend already owns.
    init(openSeat: CardCode) throws {
        try self.init(openSeat.rawValue)
    }
}
