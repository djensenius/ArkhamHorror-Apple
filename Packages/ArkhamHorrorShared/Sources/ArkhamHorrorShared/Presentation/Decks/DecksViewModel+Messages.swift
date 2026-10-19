extension DecksViewModel {
    nonisolated static func message(for error: any Error) -> String {
        if let deckError = error as? DeckServiceError {
            return deckError.message
        }
        if let gameError = error as? GameLifecycleTokenAccessError {
            switch gameError {
            case .stale:
                return ""
            case .noToken:
                return "Your session is no longer available. Sign in again to manage decks."
            case .tokenStore:
                return "The saved session token could not be read. Try signing in again."
            }
        }
        return "The deck operation failed. Try again."
    }
}
