/// A one-shot notice that the server closed a live game room.
///
/// Kept on the shared model rather than only in ``LiveGameState`` so it can be
/// rendered by the surviving games-list surface after confirmed-delete
/// reconciliation pops the live game route.
struct RoomClosedNotice: Equatable, Identifiable, Sendable {
    let gameID: GameID
    let reason: String

    var id: GameID {
        gameID
    }

    /// `RoomClosed` reasons the server sends while the game itself still exists: the last
    /// player left (`abandoned`, Api/Arkham/Helpers.hs `closeAbandonedRoom`) or the server
    /// entered maintenance (`maintenance`, `applyMaintenance`). Any other reason, including
    /// `deleted`, keeps the deleted-game handling.
    static func keepsGame(reason: String) -> Bool {
        reason == "abandoned" || reason == "maintenance"
    }
}
