import Foundation

enum GameLobbyViewerSeatStatus: Equatable {
    case unresolved
    case failed(GameLifecycleError)
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
        case let .failed(error):
            return gameLifecycleLocalizedFormat(
                "games.lobby.openSeats.checkingSeat.failed",
                "Could not check whether you already have a seat: %@",
                error.message
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
        if let failure = model.gameLobbyViewerSeatFailures[gameID] {
            return .failed(failure)
        }
        guard let viewerHasSeat = model.gameLobbyViewerHasSeats[gameID] else {
            return .unresolved
        }
        return viewerHasSeat ? .seated : .unseated
    }

    func retryLobbySeatStatus() {
        model.loadLobbyDetailsIfNeeded(for: gameID)
    }
}
