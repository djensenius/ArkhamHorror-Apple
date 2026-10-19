import Foundation

extension AppModel {
    // MARK: - Choose deck

    /// Continues without upgrading a claimed seat's deck (``ChooseDeckRequest`` with
    /// no deck source) for `rawInvestigatorId` (an already-claimed seat's
    /// investigator, as reported by the game's own `investigators` summary) in `id`,
    /// and refreshes the games list on success.
    func continueWithoutUpgrading(investigatorId rawInvestigatorId: String, in id: GameID) {
        chooseDeck(nil, investigatorId: rawInvestigatorId, in: id)
    }

    /// Chooses a saved deck for a claimed investigator using the existing pre-game REST
    /// route (`PUT /arkham/games/{gameId}/decks`) and the same body semantics as the web
    /// lobby route: investigator id plus deck URL/list, never a saved-deck id.
    func chooseDeck(_ deck: Deck, investigatorId rawInvestigatorId: String, in id: GameID) {
        chooseDeck(.saved(deck), investigatorId: rawInvestigatorId, in: id)
    }

    private enum DeckChoiceSource: Sendable {
        case saved(Deck)

        var deckURL: String? {
            switch self {
            case let .saved(deck):
                deck.url ?? deck.list.url
            }
        }

        var deckList: DeckListInput {
            switch self {
            case let .saved(deck):
                DeckListInput(deck.playableList)
            }
        }
    }

    private func chooseDeck(_ source: DeckChoiceSource?, investigatorId: String, in id: GameID) {
        guard let attempt = beginGameAction(id, kind: .choosingDeck) else { return }
        gameLifecycleActionTasks[id] = Task { [weak self] in
            await self?.performChooseDeck(
                source,
                investigatorId: investigatorId,
                in: id,
                attempt: attempt
            )
        }
    }

    private func resolveDeckChoiceSource(
        _ source: DeckChoiceSource?,
        profile: ServerProfile,
        context: DeckRequestContext
    ) async throws -> DeckChoiceSource? {
        switch source {
        case let .saved(deck):
            let syncResult = try await syncDeckBeforeChoiceIfNeeded(
                deck,
                profile: profile,
                context: context
            )
            return .saved(syncResult.deck)
        case nil:
            return nil
        }
    }

    private func handleChooseDeckSessionExpired(
        id: GameID,
        attempt: GameActionAttempt,
        context: DeckRequestContext
    ) async {
        if isCurrentGameAction(id, attempt) {
            await handleDeckSessionExpired(profile: attempt.profile, context: context)
        }
    }

    private func performChooseDeck(
        _ source: DeckChoiceSource?, investigatorId rawInvestigatorId: String, in id: GameID,
        attempt: GameActionAttempt
    ) async {
        guard let token = await resolveGameActionToken(id, kind: .choosingDeck, attempt: attempt)
        else { return }
        guard let investigatorId = try? InvestigatorCode(rawInvestigatorId) else {
            recordGameActionFailure(
                id, attempt: attempt, kind: .choosingDeck, error: .malformedPayload
            )
            return
        }
        let context = DeckRequestContext(
            token: token,
            sessionGeneration: attempt.sessionGeneration,
            credentialEpoch: attempt.credentialEpoch,
            globalEpoch: attempt.globalEpoch
        )
        let resolvedSource: DeckChoiceSource?
        do {
            resolvedSource = try await resolveDeckChoiceSource(
                source,
                profile: attempt.profile,
                context: context
            )
        } catch DeckServiceError.sessionExpired {
            recordGameActionFailure(
                id,
                attempt: attempt,
                kind: .choosingDeck,
                error: .sessionExpired
            )
            await handleChooseDeckSessionExpired(id: id, attempt: attempt, context: context)
            return
        } catch {
            clearGameActionMarkerIfCurrent(id, attempt)
            return
        }
        guard !Task.isCancelled, isCurrentGameAction(id, attempt) else {
            clearGameActionMarkerIfCurrent(id, attempt)
            return
        }
        let request = ChooseDeckRequest(
            investigatorId: investigatorId,
            deckUrl: resolvedSource?.deckURL,
            deckList: resolvedSource?.deckList
        )
        await performGameAction(id, kind: .choosingDeck, attempt: attempt) {
            try await self.gameLifecycleService.chooseDeck(
                request, in: id, on: attempt.profile, token: token
            )
        } onSuccess: {
            self.refreshGames()
        }
    }
}
