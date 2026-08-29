/// The authenticated games list's load state, tracked by
/// `AppModel.gameListState`.
enum GameListLoadState: Sendable {
    /// Never yet loaded for the current signed-in session.
    case idle
    /// A load or refresh is in flight. Carries the previously loaded list, if any, so
    /// a refresh can keep showing prior content (rather than flashing empty) while it
    /// completes.
    case loading(previous: GameList?)
    /// The list loaded successfully.
    case loaded(GameList)
    /// The list failed to load. Carries the previously loaded list, if any, so a
    /// failed refresh does not discard content that was already on screen.
    case failed(GameLifecycleError, previous: GameList?)
}

extension GameListLoadState: Equatable {}

extension GameListLoadState {
    /// The most recent successfully loaded list, whether or not a load/refresh is
    /// currently in flight or most recently failed. `nil` only before any load has
    /// ever succeeded.
    var games: GameList? {
        switch self {
        case .idle:
            nil
        case let .loading(previous), let .failed(_, previous):
            previous
        case let .loaded(games):
            games
        }
    }

    var isLoading: Bool {
        if case .loading = self {
            true
        } else {
            false
        }
    }
}

/// The kind of per-game lifecycle action currently in flight, if any, tracked by
/// `AppModel.gameLifecycleActions`.
///
/// Keyed per-``GameID`` (not a single shared value) since independent games may have
/// independent in-flight actions at once (for example, deleting one game while
/// claiming a seat in another); actions on the *same* game are serialized (see
/// `AppModel.gameLifecycleActionAttempts`).
enum GameLifecycleAction: Equatable, Sendable {
    case deleting
    case joining
    case loadingOpenSeats
    case claimingSeat
    case choosingDeck
}

extension GameLifecycleAction {
    /// A non-secret diagnostic message for a transport-level (non-``GameLifecycleError``)
    /// failure of this action, used to build a ``GameLifecycleError/transportFailure(_:)``.
    var diagnosticFailureMessage: String {
        switch self {
        case .deleting: "Unexpected delete failure."
        case .joining: "Unexpected join failure."
        case .loadingOpenSeats: "Unexpected open-seats failure."
        case .claimingSeat: "Unexpected claim-seat failure."
        case .choosingDeck: "Unexpected choose-deck failure."
        }
    }
}

/// A ``GameLifecycleError`` tagged with the exact action that produced it, tracked by
/// `AppModel.gameLifecycleActionFailures`, keyed per-``GameID``.
struct GameLifecycleActionFailure: Equatable, Sendable {
    let action: GameLifecycleAction
    let error: GameLifecycleError
}

extension GameLifecycleError {
    /// A short, user-facing, non-secret summary of this failure.
    var message: String {
        switch self {
        case .sessionExpired:
            "Your session has expired. Sign in again to continue."
        case .nonHTTPResponse, .transportFailure:
            "This server could not be reached. Check your connection and try again."
        case let .unexpectedStatus(code) where code == 403:
            "That action isn't available for this game right now."
        case let .unexpectedStatus(code) where code == 404:
            "This game is no longer available."
        case .unexpectedStatus, .malformedPayload:
            "This server responded unexpectedly. Try again."
        case .requestEncodingFailed, .invalidPathSegment:
            "This request couldn't be made. Try again."
        case .tokenUnavailable:
            "Could not securely access your session. Try again."
        }
    }
}

extension GameListEntry {
    /// This entry's ``GameID``, if it decoded successfully. `nil` for a ``failed``
    /// row, which carries only an opaque error string and never an ID.
    var gameID: GameID? {
        if case let .game(summary) = self {
            summary.id
        } else {
            nil
        }
    }
}

extension GameSummary {
    /// The scenario or campaign name to display for this game, falling back to the
    /// game's own stored `name` when neither is present.
    var displayName: String {
        if let scenario {
            scenario.name.title
        } else {
            name
        }
    }

    /// A short, user-facing subtitle summarizing scenario/campaign difficulty and
    /// multiplayer mode, without exposing any raw identifier.
    var displaySubtitle: String {
        var parts: [String] = []
        if let difficulty = scenario?.difficulty ?? campaign?.difficulty {
            parts.append(difficulty.description)
        }
        parts.append(multiplayerVariant == .withFriends ? "With Friends" : "Solo")
        return parts.joined(separator: " · ")
    }
}

extension GameState {
    /// A short, user-facing, non-secret summary of this state.
    var statusText: String {
        switch self {
        case let .pending(players):
            "Pending lobby (\(players.count) joined)"
        case let .chooseDecks(players):
            "Choosing decks (\(players.count) waiting)"
        case .active:
            "In progress"
        case .over:
            "Completed"
        case .unknown:
            "Update required"
        }
    }
}
