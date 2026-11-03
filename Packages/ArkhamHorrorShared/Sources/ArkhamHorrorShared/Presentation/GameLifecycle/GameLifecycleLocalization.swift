import Foundation

func gameLifecycleLocalized(_ key: String, _ fallback: String) -> String {
    NSLocalizedString(key, bundle: .module, value: fallback, comment: "")
}

func gameLifecycleLocalizedFormat(
    _ key: String,
    _ fallback: String,
    _ arguments: CVarArg...
) -> String {
    String(
        format: gameLifecycleLocalized(key, fallback),
        locale: Locale(identifier: Locale.current.identifier),
        arguments: arguments
    )
}

func gameLifecycleLocalizedPlural(
    count: Int,
    oneKey: String,
    oneFallback: String,
    manyKey: String,
    manyFallback: String
) -> String {
    if count == 1 {
        gameLifecycleLocalized(oneKey, oneFallback)
    } else {
        gameLifecycleLocalizedFormat(manyKey, manyFallback, count)
    }
}

func liveGameRoomClosedTitle() -> String {
    gameLifecycleLocalized("games.live.roomClosed.title", "Game closed")
}

func liveGameRoomClosedMessage(reason: String? = nil) -> String {
    switch reason {
    case "abandoned":
        gameLifecycleLocalized(
            "games.live.roomClosed.message.abandoned",
            "Every player left this game, so the server closed its room."
        )
    case "maintenance":
        gameLifecycleLocalized(
            "games.live.roomClosed.message.maintenance",
            "The server is down for maintenance. Open the game again once it is back."
        )
    case nil, "deleted":
        gameLifecycleLocalized(
            "games.live.roomClosed.message",
            "This game was closed on the server."
        )
    default:
        // `swept` (an admin closed an idle room) and reasons this client doesn't know: the
        // game still exists.
        gameLifecycleLocalized(
            "games.live.roomClosed.message.reopen",
            "The server closed this game's room. Reopen it to continue."
        )
    }
}
