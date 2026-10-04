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

    func liveChooseDeckRejectionReason(
        for gameID: GameID, promptKey: BasicChoicePromptKey
    ) -> String? {
        guard basicChoiceServerFeedbackSources[gameID] == .answerRejected else { return nil }
        return liveChooseDeckServerFeedback(for: gameID, promptKey: promptKey)
    }

    func liveChooseDeckServerFeedback(
        for gameID: GameID, promptKey: BasicChoicePromptKey
    ) -> String? {
        guard let prompt = basicChoicePresentation(for: gameID),
              prompt.identity.promptKey == promptKey,
              LiveChooseDeckQuestion.matches(prompt.identity.rawQuestion)
        else { return nil }
        return basicChoiceServerFeedback[gameID]
    }

    func liveChooseDeckIsAwaitingAnswer(
        for gameID: GameID, promptKey: BasicChoicePromptKey
    ) -> Bool {
        guard let prompt = basicChoicePresentation(for: gameID),
              prompt.identity.promptKey == promptKey,
              LiveChooseDeckQuestion.matches(prompt.identity.rawQuestion),
              let action = basicChoiceActions[gameID],
              action.identity.promptKey == promptKey,
              case .deck = action.submission
        else { return false }
        switch action.phase {
        case .sending, .awaitingSnapshot, .uncertain:
            return true
        case .retryable:
            return false
        }
    }

    /// Answers the live, in-game `ChooseDeck` prompt using the same WebSocket answer
    /// family as the web client. This is intentionally separate from the pre-game
    /// REST `PUT /games/{id}/decks` upgrade/replace route.
    func chooseDeckForLivePrompt(_ deck: Deck, in gameID: GameID) async -> Bool {
        guard case .canAnswer = canAnswerLiveChooseDeck(for: gameID),
              let prompt = basicChoicePresentation(for: gameID),
              let connection = liveGameConnections[gameID]
        else { return false }
        guard let actionAttemptID = prepareLiveChooseDeckSend(
            prompt: prompt.identity,
            deckID: deck.id,
            connection: connection
        ) else { return false }

        do {
            try Task.checkCancellation()
            let bytes = try ContractJSON.encode(DeckAnswer(
                deckId: deck.id,
                playerId: prompt.ownerID
            ))
            try await connection.connection.send(bytes)
        } catch {
            if consumeBasicChoiceRejectedAttempt(
                gameID: gameID,
                actionAttemptID: actionAttemptID
            ) {
                return true
            }
            clearLiveChooseDeckAction(
                gameID: gameID,
                actionAttemptID: actionAttemptID,
                connectionID: connection.connectionID
            )
            return false
        }

        if consumeBasicChoiceRejectedAttempt(
            gameID: gameID,
            actionAttemptID: actionAttemptID
        ) {
            return true
        }
        guard liveGameConnections[gameID]?.connectionID == connection.connectionID,
              basicChoiceActions[gameID]?.attemptID == actionAttemptID,
              basicChoiceActions[gameID]?.identity == prompt.identity,
              basicChoiceActions[gameID]?.submission == .deck(deck.id),
              basicChoiceActions[gameID]?.phase == .sending
        else { return false }
        basicChoiceActions[gameID]?.phase = .awaitingSnapshot
        return true
    }

    private func prepareLiveChooseDeckSend(
        prompt: BasicChoicePromptIdentity,
        deckID: DeckID,
        connection: LiveGameConnectionHandle
    ) -> UUID? {
        if let action = basicChoiceActions[prompt.gameID] {
            guard action.identity.promptKey == prompt.promptKey else {
                basicChoiceActions[prompt.gameID] = nil
                return prepareLiveChooseDeckSend(
                    prompt: prompt,
                    deckID: deckID,
                    connection: connection
                )
            }
            guard case .retryable = action.phase,
                  case .deck = action.submission
            else { return nil }
        }
        clearBasicChoiceServerFeedback(gameID: prompt.gameID)
        let actionAttemptID = UUID()
        basicChoiceActions[prompt.gameID] = BasicChoiceActionRecord(
            identity: prompt,
            submission: .deck(deckID),
            attemptID: actionAttemptID,
            connectionID: connection.connectionID,
            phase: .sending
        )
        return actionAttemptID
    }

    private func clearLiveChooseDeckAction(
        gameID: GameID,
        actionAttemptID: UUID,
        connectionID: UUID
    ) {
        guard basicChoiceActions[gameID]?.attemptID == actionAttemptID,
              basicChoiceActions[gameID]?.connectionID == connectionID,
              basicChoiceActions[gameID]?.phase == .sending
        else { return }
        basicChoiceActions[gameID] = nil
    }
}
