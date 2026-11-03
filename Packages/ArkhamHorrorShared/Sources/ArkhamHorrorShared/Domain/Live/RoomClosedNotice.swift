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

    /// Whether a `RoomClosed` reason means the game itself was deleted. Only `deleted`
    /// (Api/Handler/Arkham/Games/Shared.hs, Admin.hs delete) does. Every other reason keeps the
    /// game listed: `abandoned` (the last player left), `maintenance` (the server entered
    /// maintenance), an admin `swept` of an idle room, and any reason this client doesn't know.
    /// Servers before schema 0.1.57 only send `deleted`.
    static func deletesGame(reason: String) -> Bool {
        reason == "deleted"
    }
}
