import Foundation

enum GameLobbyViewerSeatStatus: Equatable {
    case unresolved
    case unseated
    case seated
}

extension GameLobbyView {
    func showsClaimSeatButtons(for game: GameSummary, openSeats: OpenSeats) -> Bool {
        !openSeats.isEmpty && viewerSeatStatus(in: game) == .unseated
    }

    func openSeatsStatusText(for game: GameSummary, openSeats: OpenSeats) -> String {
        switch viewerSeatStatus(in: game) {
        case .seated:
            return gameLifecycleLocalized(
                "games.lobby.openSeats.alreadyClaimed",
                "You already have a seat in this game."
            )
        case .unresolved:
            return gameLifecycleLocalized(
                "games.lobby.openSeats.checkingSeat",
                "Checking whether you already have a seat in this game."
            )
        case .unseated:
            if openSeats.isEmpty {
                return gameLifecycleLocalized(
                    "games.lobby.openSeats.empty",
                    "No open seats remain."
                )
            }
            return ""
        }
    }

    func viewerSeatStatus(in _: GameSummary) -> GameLobbyViewerSeatStatus {
        guard let viewerHasSeat = model.gameLobbyViewerHasSeats[gameID] else {
            return .unresolved
        }
        return viewerHasSeat ? .seated : .unseated
    }
}
