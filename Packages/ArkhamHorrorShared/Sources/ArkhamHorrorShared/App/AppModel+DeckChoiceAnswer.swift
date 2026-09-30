import Foundation

enum LiveChooseDeckAnswerability: Sendable, Equatable {
    case canAnswer(promptKey: BasicChoicePromptKey)
    case readOnly(String)

    var promptKey: BasicChoicePromptKey? {
        switch self {
        case let .canAnswer(promptKey):
            promptKey
        case .readOnly:
            nil
        }
    }
}

extension AppModel {
    func canAnswerLiveChooseDeck(for gameID: GameID) -> LiveChooseDeckAnswerability {
        guard let prompt = basicChoicePresentation(for: gameID),
              LiveChooseDeckQuestion.matches(prompt.identity.rawQuestion)
        else { return .readOnly("This game is not currently asking you to choose a deck.") }
        guard case let .participant(playerID) = liveGameParticipantIdentities[gameID] else {
            return .readOnly("Spectators cannot choose decks for this game.")
        }
        guard playerID == prompt.ownerID else {
            return .readOnly("This deck choice belongs to another player.")
        }
        guard case let .signedIn(_, compatibility, _) = sessionState,
              case .modern = compatibility
        else {
            return .readOnly(
                "Update or reconnect to a contract-compatible server to choose a deck."
            )
        }
        guard let connection = liveGameConnections[gameID],
              liveGameSessions[gameID]?.attemptID == connection.attemptID
        else { return .readOnly("Reconnect to choose a deck.") }
        return .canAnswer(promptKey: prompt.identity.promptKey)
    }

    /// Answers the live, in-game `ChooseDeck` prompt using the same WebSocket answer
    /// family as the web client. This is intentionally separate from the pre-game
    /// REST `PUT /games/{id}/decks` upgrade/replace route.
    func chooseDeckForLivePrompt(_ deck: Deck, in gameID: GameID) async -> Bool {
        guard case .canAnswer = canAnswerLiveChooseDeck(for: gameID),
              let prompt = basicChoicePresentation(for: gameID),
              let connection = liveGameConnections[gameID]
        else { return false }

        do {
            try Task.checkCancellation()
            let bytes = try ContractJSON.encode(DeckAnswer(
                deckId: deck.id,
                playerId: prompt.ownerID
            ))
            try await connection.connection.send(bytes)
            return true
        } catch {
            return false
        }
    }
}
