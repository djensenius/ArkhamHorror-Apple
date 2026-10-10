import Foundation

extension AppModel {
    func canAnswerLiveChooseDeck(for gameID: GameID) -> LiveChooseDeckAnswerability {
        guard let prompt = basicChoicePresentation(for: gameID),
              LiveChooseDeckQuestion.matches(prompt.identity.rawQuestion)
        else {
            return .readOnly(liveChooseDeckLocalized(
                "liveChooseDeck.readOnly.notChoosingDeck",
                "This game is not currently asking you to choose a deck."
            ))
        }
        guard case let .participant(playerID) = liveGameParticipantIdentities[gameID] else {
            return .readOnly(liveChooseDeckLocalized(
                "liveChooseDeck.readOnly.spectator",
                "Spectators cannot choose decks for this game."
            ))
        }
        guard playerID == prompt.ownerID else {
            return .readOnly(liveChooseDeckLocalized(
                "liveChooseDeck.readOnly.otherPlayer",
                "This deck choice belongs to another player."
            ))
        }
        guard case let .signedIn(_, compatibility, _) = sessionState,
              case .modern = compatibility
        else {
            return .readOnly(liveChooseDeckLocalized(
                "liveChooseDeck.readOnly.incompatibleServer",
                "Update or reconnect to a contract-compatible server to choose a deck."
            ))
        }
        guard let connection = liveGameConnections[gameID],
              liveGameSessions[gameID]?.attemptID == connection.attemptID
        else {
            return .readOnly(liveChooseDeckLocalized(
                "liveChooseDeck.readOnly.reconnect",
                "Reconnect to choose a deck."
            ))
        }
        return .canAnswer(promptKey: prompt.identity.promptKey)
    }

    func refreshLiveChooseDeckRestriction(for gameID: GameID) async {
        let context = liveChooseDeckRestrictionContext(for: gameID)
        let cacheKey = liveChooseDeckRestrictionCacheKey(for: context)

        guard liveChooseDeckRestrictionCacheKeys[gameID] != cacheKey ||
            liveChooseDeckRestrictionChecks[gameID] == nil ||
            liveChooseDeckRestrictionChecks[gameID] == .loading
        else { return }

        let refreshID = UUID()
        liveChooseDeckRestrictionRefreshIDs[gameID] = refreshID

        guard context.shouldCheckCatalog else {
            liveChooseDeckRestrictionChecks[gameID] = .unrestricted(scenarioID: context.scenarioID)
            liveChooseDeckRestrictionCacheKeys[gameID] = cacheKey
            return
        }

        liveChooseDeckRestrictionChecks[gameID] = .loading
        do {
            let check = try await loadLiveChooseDeckRestriction(for: context)
            guard !Task.isCancelled,
                  liveChooseDeckRestrictionRefreshIDs[gameID] == refreshID
            else { return }
            guard liveChooseDeckRestrictionCacheKey(
                for: liveChooseDeckRestrictionContext(for: gameID)
            ) == cacheKey else {
                liveChooseDeckRestrictionChecks[gameID] = nil
                liveChooseDeckRestrictionCacheKeys[gameID] = nil
                return
            }
            liveChooseDeckRestrictionChecks[gameID] = check
            liveChooseDeckRestrictionCacheKeys[gameID] = cacheKey
        } catch is CancellationError {
            guard liveChooseDeckRestrictionRefreshIDs[gameID] == refreshID else { return }
            liveChooseDeckRestrictionChecks[gameID] = nil
        } catch {
            guard liveChooseDeckRestrictionRefreshIDs[gameID] == refreshID else { return }
            guard liveChooseDeckRestrictionCacheKey(
                for: liveChooseDeckRestrictionContext(for: gameID)
            ) == cacheKey else {
                liveChooseDeckRestrictionChecks[gameID] = nil
                liveChooseDeckRestrictionCacheKeys[gameID] = nil
                return
            }
            liveChooseDeckRestrictionChecks[gameID] = .unavailable(
                message: liveChooseDeckRestrictionUnavailableMessage(),
                scenarioID: context.scenarioID
            )
        }
    }

    func liveChooseDeckRestrictionNotice(for gameID: GameID) -> String? {
        liveChooseDeckRestrictionChecks[gameID]?.notice(
            tableState: liveChooseDeckRestrictionTableState(for: gameID)
        )
    }

    func liveChooseDeckRestrictionValidationMessage(for deck: Deck, in gameID: GameID) -> String? {
        liveChooseDeckRestrictionChecks[gameID]?.rejectionMessage(
            for: deck,
            currentScenarioID: liveChooseDeckScenarioID(for: gameID),
            tableState: liveChooseDeckRestrictionTableState(for: gameID)
        )
    }

    func liveChooseDeckRestrictionDeckError(for deck: Deck, in gameID: GameID) -> String? {
        guard case .requiresInvestigator? = liveChooseDeckRestrictionChecks[gameID] else {
            return nil
        }
        return liveChooseDeckRestrictionValidationMessage(for: deck, in: gameID)
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

    func liveChooseDeckPickerEnabled(
        for gameID: GameID,
        promptKey: BasicChoicePromptKey,
        validation: LobbyDeckSelectionViewModel.ValidationState
    ) -> Bool {
        liveChooseDeckPickerEnabled(
            for: gameID,
            promptKey: promptKey,
            validation: validation,
            deck: nil
        )
    }

    func liveChooseDeckPickerEnabled(
        for gameID: GameID,
        promptKey: BasicChoicePromptKey,
        validation: LobbyDeckSelectionViewModel.ValidationState,
        deck: Deck?
    ) -> Bool {
        guard validation == .valid else { return false }
        if let deck, liveChooseDeckRestrictionValidationMessage(for: deck, in: gameID) != nil {
            return false
        }
        return !liveChooseDeckIsAwaitingAnswer(for: gameID, promptKey: promptKey)
    }

    /// Answers the live, in-game `ChooseDeck` prompt using the same WebSocket answer
    /// family as the web client. This is intentionally separate from the pre-game
    /// REST `PUT /games/{id}/decks` upgrade/replace route.
    func chooseDeckForLivePrompt(_ deck: Deck, in gameID: GameID) async -> Bool {
        guard liveChooseDeckRestrictionValidationMessage(for: deck, in: gameID) == nil,
              case .canAnswer = canAnswerLiveChooseDeck(for: gameID),
              let prompt = basicChoicePresentation(for: gameID),
              let connection = liveGameConnections[gameID]
        else { return false }
        guard let actionAttemptID = prepareLiveChooseDeckSend(
            prompt: prompt.identity,
            deckID: deck.id,
            connection: connection
        ) else { return false }

        var didStartSend = false
        do {
            try Task.checkCancellation()
            let bytes = try ContractJSON.encode(DeckAnswer(
                deckId: deck.id,
                playerId: prompt.ownerID
            ))
            didStartSend = true
            try await connection.connection.send(bytes)
            try Task.checkCancellation()
        } catch is CancellationError {
            return failLiveChooseDeckSend(
                gameID: gameID,
                actionAttemptID: actionAttemptID,
                connectionID: connection.connectionID,
                phase: didStartSend ? .uncertain : .retryable(.transportFailure)
            )
        } catch {
            return failLiveChooseDeckSend(
                gameID: gameID,
                actionAttemptID: actionAttemptID,
                connectionID: connection.connectionID,
                phase: .retryable(.transportFailure)
            )
        }

        return finishLiveChooseDeckSend(
            gameID: gameID,
            prompt: prompt.identity,
            deckID: deck.id,
            actionAttemptID: actionAttemptID,
            connectionID: connection.connectionID
        )
    }

    private func loadLiveChooseDeckRestriction(
        for context: LiveChooseDeckRestrictionContext
    ) async throws -> LiveChooseDeckRestrictionCheck {
        guard case let .signedIn(profile, compatibility, _) = sessionState,
              compatibility.modernCapabilities.contains(
                  ServerCompatibility.campaignCatalogCapability
              ),
              let advertisement = compatibility.campaignCatalogAdvertisement
        else {
            return .unavailable(
                message: liveChooseDeckRestrictionUnavailableMessage(),
                scenarioID: context.scenarioID
            )
        }
        try Task.checkCancellation()
        let document = try await campaignCatalogService.load(
            on: profile,
            advertisement: advertisement
        )
        try Task.checkCancellation()
        return LiveChooseDeckRestrictionCatalogLookup.check(
            for: context.rawScenarioID,
            in: document
        )
    }

    private func liveChooseDeckScenarioID(for gameID: GameID) -> String? {
        liveChooseDeckRestrictionContext(for: gameID).rawScenarioID
    }

    private func liveChooseDeckRestrictionContext(
        for gameID: GameID
    ) -> LiveChooseDeckRestrictionContext {
        guard let projection = liveGameStates[gameID]?.lastKnownProjection,
              let scenario = projection.scenario
        else { return LiveChooseDeckRestrictionContext(rawScenarioID: nil, isSideStory: nil) }
        return LiveChooseDeckRestrictionContext(
            rawScenarioID: scenario.id,
            isSideStory: scenario.isSideStory
        )
    }

    private func liveChooseDeckRestrictionCacheKey(
        for context: LiveChooseDeckRestrictionContext
    ) -> LiveChooseDeckRestrictionCacheKey {
        LiveChooseDeckRestrictionCacheKey(
            scenarioID: context.scenarioID,
            isSideStory: context.isSideStory,
            catalogRevision: liveChooseDeckCampaignCatalogRevision()
        )
    }

    private func liveChooseDeckCampaignCatalogRevision() -> String? {
        guard case let .signedIn(_, compatibility, _) = sessionState,
              compatibility.modernCapabilities.contains(
                  ServerCompatibility.campaignCatalogCapability
              )
        else { return nil }
        return compatibility.campaignCatalogAdvertisement?.catalogRevision
    }

    private func liveChooseDeckRestrictionUnavailableMessage() -> String {
        liveChooseDeckLocalized(
            "liveChooseDeck.restriction.unavailable",
            "Side-story investigator requirements cannot be checked right now. "
                + "Make sure this deck uses the scenario's required investigator."
        )
    }

    private func finishLiveChooseDeckSend(
        gameID: GameID,
        prompt: BasicChoicePromptIdentity,
        deckID: DeckID,
        actionAttemptID: UUID,
        connectionID: UUID
    ) -> Bool {
        if consumeBasicChoiceRejectedAttempt(gameID: gameID, actionAttemptID: actionAttemptID) {
            return true
        }
        guard liveGameConnections[gameID]?.connectionID == connectionID,
              basicChoiceActions[gameID]?.attemptID == actionAttemptID,
              basicChoiceActions[gameID]?.identity == prompt,
              basicChoiceActions[gameID]?.submission == .deck(deckID),
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

    private func failLiveChooseDeckSend(
        gameID: GameID,
        actionAttemptID: UUID,
        connectionID: UUID,
        phase: BasicChoiceActionPhase
    ) -> Bool {
        if consumeBasicChoiceRejectedAttempt(gameID: gameID, actionAttemptID: actionAttemptID) {
            return true
        }
        markLiveChooseDeckAction(
            gameID: gameID,
            actionAttemptID: actionAttemptID,
            connectionID: connectionID,
            phase: phase
        )
        return false
    }

    private func markLiveChooseDeckAction(
        gameID: GameID,
        actionAttemptID: UUID,
        connectionID: UUID,
        phase: BasicChoiceActionPhase
    ) {
        guard basicChoiceActions[gameID]?.attemptID == actionAttemptID,
              basicChoiceActions[gameID]?.connectionID == connectionID,
              basicChoiceActions[gameID]?.phase == .sending
        else { return }
        basicChoiceActions[gameID]?.phase = phase
    }
}

func normalizedScenarioID(_ scenarioID: String?) -> String? {
    scenarioID.map(normalizedCardCode)
}

func normalizedCardCode(_ code: String) -> String {
    code.hasPrefix("c") ? String(code.dropFirst()) : code
}

func liveChooseDeckLocalized(_ key: String, _ fallback: String) -> String {
    NSLocalizedString(key, bundle: .module, value: fallback, comment: "")
}
