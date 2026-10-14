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
}
