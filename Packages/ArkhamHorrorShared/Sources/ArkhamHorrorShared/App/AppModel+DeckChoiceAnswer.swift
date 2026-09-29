import Foundation

extension AppModel {
    /// Answers the live, in-game `ChooseDeck` prompt using the same WebSocket answer
    /// family as the web client. This is intentionally separate from the pre-game
    /// REST `PUT /games/{id}/decks` upgrade/replace route.
    func chooseDeckForLivePrompt(_ deck: Deck, in gameID: GameID) async -> Bool {
        guard let prompt = basicChoicePresentation(for: gameID),
              LiveChooseDeckQuestion.matches(prompt.identity.rawQuestion),
              prompt.isAuthorized,
              let connection = liveGameConnections[gameID],
              liveGameSessions[gameID]?.attemptID == connection.attemptID
        else { return false }

        do {
            let bytes = try ContractJSON.encode(DeckAnswer(
                deckId: deck.id,
                playerId: prompt.ownerID
            ))
            try await connection.connection.send(bytes)
            try Task.checkCancellation()
            return true
        } catch {
            return false
        }
    }
}
