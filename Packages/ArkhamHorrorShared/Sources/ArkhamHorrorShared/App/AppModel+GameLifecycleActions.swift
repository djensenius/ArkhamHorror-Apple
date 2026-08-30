import Foundation

/// The attempt identity and profile captured by `beginGameAction(_:kind:)` and
/// threaded through a per-game action's async body. A small named type (rather than
/// a 3-element tuple) keeps every call site within this project's tuple-arity
/// convention.
private struct GameActionAttempt: Sendable {
    let profile: ServerProfile
    let attemptID: UUID
    let sessionGeneration: Int
    let credentialEpoch: Int
    let globalEpoch: Int
}

/// Per-game lifecycle actions (delete/join/open-seats/claim-seat/choose-deck),
/// bound to `AppModel`'s existing single session/token authority.
///
/// Split out of `AppModel+GameLifecycle.swift` purely by file length; every member
/// here shares that file's exact staleness/token/session-expiry guarantees (see its
/// documentation) scoped per-``GameID`` instead of to the shared games list: an
/// action superseded by a newer action on the *same* game (see
/// ``AppModel/gameLifecycleActionAttempts``) can never have its stale completion
/// mutate ``AppModel/gameLifecycleActions``/``AppModel/gameLifecycleActionFailures``/
/// ``AppModel/gameOpenSeats`` after that newer action has already started, and
/// actions on independent games never interfere with each other.
extension AppModel {
    private func isCurrentGameAction(_ id: GameID, _ attempt: GameActionAttempt) -> Bool {
        isCurrent(attempt.sessionGeneration) && gameLifecycleActionAttempts[id] == attempt.attemptID
    }

    /// Clears `id`'s in-flight action marker when, and only when, `attempt` is still
    /// this game's current action -- shared by every path that must revert the
    /// "in flight" UI state without reporting a failure (cancellation and a stale
    /// credential-epoch token read, both of which mean *something else* already
    /// superseded or invalidated this read, not that the action itself failed). A
    /// superseded action's own stale completion is left completely untouched here,
    /// exactly like every other stale-completion guard in this file.
    private func clearGameActionMarkerIfCurrent(_ id: GameID, _ attempt: GameActionAttempt) {
        guard isCurrentGameAction(id, attempt) else { return }
        gameLifecycleActions[id] = nil
    }

    /// Marks `id` as having `kind` in flight: cancels and supersedes any previous
    /// action already running for `id`, clears its prior failure, and returns the new
    /// attempt's identity together with the currently signed-in profile -- or `nil`
    /// if not currently signed in.
    private func beginGameAction(_ id: GameID, kind: GameLifecycleAction) -> GameActionAttempt? {
        guard case let .signedIn(profile, _, _) = sessionState else { return nil }
        gameLifecycleActionTasks[id]?.cancel()
        let attemptID = UUID()
        gameLifecycleActionAttempts[id] = attemptID
        gameLifecycleActions[id] = kind
        gameLifecycleActionFailures[id] = nil
        return GameActionAttempt(
            profile: profile,
            attemptID: attemptID,
            sessionGeneration: generation,
            credentialEpoch: currentCredentialEpoch(for: profile.id),
            globalEpoch: currentGlobalCredentialEpoch()
        )
    }

    private func recordGameActionFailure(
        _ id: GameID,
        attempt: GameActionAttempt,
        kind: GameLifecycleAction,
        error: GameLifecycleError
    ) {
        guard isCurrentGameAction(id, attempt) else { return }
        gameLifecycleActions[id] = nil
        gameLifecycleActionFailures[id] = GameLifecycleActionFailure(action: kind, error: error)
    }

    /// Resolves this action's bearer token, recording a typed failure (and clearing
    /// the in-flight action marker) on every non-stale failure. Returns `nil` on any
    /// failure or staleness; callers must return immediately when `nil`. Cancellation
    /// and a stale credential-epoch read both clear the in-flight marker (via
    /// ``clearGameActionMarkerIfCurrent(_:_:)``, when `attempt` is still current)
    /// rather than reporting a failure -- a stale read means some other concurrent
    /// event (a profile-endpoint edit, sign-out, or storage reset) already
    /// invalidated this read while the profile may still be signed in, exactly like
    /// this file's own session-expiry handling treats it elsewhere -- so the row is
    /// never left stuck disabled with no way to retry, and no error is ever
    /// synthesized for a condition the backend never reported.
    private func resolveGameActionToken(
        _ id: GameID, kind: GameLifecycleAction, attempt: GameActionAttempt
    ) async -> String? {
        do {
            return try await currentGameLifecycleToken(for: attempt.profile)
        } catch is CancellationError {
            clearGameActionMarkerIfCurrent(id, attempt)
            return nil
        } catch let tokenError as GameLifecycleTokenAccessError {
            switch tokenError {
            case .stale:
                clearGameActionMarkerIfCurrent(id, attempt)
            case .noToken:
                recordGameActionFailure(id, attempt: attempt, kind: kind, error: .sessionExpired)
            case .tokenStore:
                recordGameActionFailure(id, attempt: attempt, kind: kind, error: .tokenUnavailable)
            }
            return nil
        } catch {
            clearGameActionMarkerIfCurrent(id, attempt)
            return nil
        }
    }

    /// Runs `body` for `id`'s already-resolved token, mapping every thrown failure
    /// to a typed, attempt-guarded ``GameLifecycleActionFailure`` (and routing a
    /// ``GameLifecycleError/sessionExpired`` through
    /// ``handleGameLifecycleSessionExpired(profile:generation:credentialEpoch:globalEpoch:)``,
    /// but only when `attempt` is still this game's current action -- checked
    /// immediately before that call, not left to that function's own,
    /// independently-fresh session check -- so a superseded action's stale 401 can
    /// never delete a newer action's, or a newer sign-in's, token) so every action
    /// function below only needs to supply its own service call and success
    /// handling. The diagnostic message for a non-``GameLifecycleError`` failure is
    /// derived from `kind` (see ``GameLifecycleAction/diagnosticFailureMessage``)
    /// rather than taken as a separate parameter, keeping this within this
    /// project's function-parameter-count convention.
    ///
    /// Cancellation is never recorded as a failure, but it must not leave `id`
    /// permanently marked in flight either: when `attempt` is *still* this game's
    /// current action at cancellation time (nothing else superseded it -- for
    /// example the underlying transport was cancelled by the system independently
    /// of any newer action ever starting), the in-flight marker is cleared so the
    /// row becomes interactive again rather than staying stuck disabled forever
    /// with no failure shown and no way to retry. When a *newer* action already
    /// superseded this one, its own marker is left completely untouched, exactly
    /// like every other stale-completion guard here.
    private func performGameAction(
        _ id: GameID,
        kind: GameLifecycleAction,
        attempt: GameActionAttempt,
        body: () async throws -> Void,
        onSuccess: () -> Void
    ) async {
        do {
            try await body()
        } catch is CancellationError {
            clearGameActionMarkerIfCurrent(id, attempt)
            return
        } catch let error as GameLifecycleError {
            recordGameActionFailure(id, attempt: attempt, kind: kind, error: error)
            if case .sessionExpired = error, isCurrentGameAction(id, attempt) {
                await handleGameLifecycleSessionExpired(
                    profile: attempt.profile,
                    generation: attempt.sessionGeneration,
                    credentialEpoch: attempt.credentialEpoch,
                    globalEpoch: attempt.globalEpoch
                )
            }
            return
        } catch {
            let error = GameLifecycleError.transportFailure(kind.diagnosticFailureMessage)
            recordGameActionFailure(id, attempt: attempt, kind: kind, error: error)
            return
        }
        guard isCurrentGameAction(id, attempt) else { return }
        gameLifecycleActions[id] = nil
        onSuccess()
    }

    // MARK: - Delete

    /// Deletes an owned game and refreshes the games list on success.
    func deleteGame(_ id: GameID) {
        guard let attempt = beginGameAction(id, kind: .deleting) else { return }
        gameLifecycleActionTasks[id] = Task { [weak self] in
            await self?.performDeleteGame(id, attempt: attempt)
        }
    }

    private func performDeleteGame(_ id: GameID, attempt: GameActionAttempt) async {
        guard let token = await resolveGameActionToken(id, kind: .deleting, attempt: attempt) else {
            return
        }
        await performGameAction(id, kind: .deleting, attempt: attempt) {
            try await self.gameLifecycleService.deleteGame(id, on: attempt.profile, token: token)
        } onSuccess: {
            self.refreshGames()
        }
    }

    // MARK: - Join

    /// Joins a pending game (idempotent server-side if already joined) and refreshes
    /// the games list on success.
    func joinGame(_ id: GameID) {
        guard let attempt = beginGameAction(id, kind: .joining) else { return }
        gameLifecycleActionTasks[id] = Task { [weak self] in
            await self?.performJoinGame(id, attempt: attempt)
        }
    }

    private func performJoinGame(_ id: GameID, attempt: GameActionAttempt) async {
        guard let token = await resolveGameActionToken(id, kind: .joining, attempt: attempt) else {
            return
        }
        await performGameAction(id, kind: .joining, attempt: attempt) {
            let envelope = try await self.gameLifecycleService.joinGame(
                id, on: attempt.profile, token: token
            )
            guard case .game = envelope else {
                throw GameLifecycleError.malformedPayload
            }
        } onSuccess: {
            self.refreshGames()
        }
    }

    // MARK: - Open seats

    /// Loads the unclaimed investigator seats for `id` into ``gameOpenSeats``.
    func loadOpenSeats(for id: GameID) {
        guard let attempt = beginGameAction(id, kind: .loadingOpenSeats) else { return }
        gameLifecycleActionTasks[id] = Task { [weak self] in
            await self?.performLoadOpenSeats(id, attempt: attempt)
        }
    }

    private func performLoadOpenSeats(_ id: GameID, attempt: GameActionAttempt) async {
        guard
            let token = await resolveGameActionToken(id, kind: .loadingOpenSeats, attempt: attempt)
        else { return }
        var loadedSeats: OpenSeats?
        await performGameAction(id, kind: .loadingOpenSeats, attempt: attempt) {
            loadedSeats = try await self.gameLifecycleService.openSeats(
                for: id, on: attempt.profile, token: token
            )
        } onSuccess: {
            self.gameOpenSeats[id] = loadedSeats
        }
    }

    // MARK: - Claim seat

    /// Claims `seat` (a code from ``gameOpenSeats``) in `id` and refreshes the games
    /// list on success.
    func claimSeat(_ seat: CardCode, in id: GameID) {
        guard let attempt = beginGameAction(id, kind: .claimingSeat) else { return }
        gameLifecycleActionTasks[id] = Task { [weak self] in
            await self?.performClaimSeat(seat, in: id, attempt: attempt)
        }
    }

    private func performClaimSeat(
        _ seat: CardCode, in id: GameID, attempt: GameActionAttempt
    ) async {
        guard let token = await resolveGameActionToken(id, kind: .claimingSeat, attempt: attempt)
        else { return }
        guard let investigatorId = try? InvestigatorCode(openSeat: seat) else {
            recordGameActionFailure(
                id, attempt: attempt, kind: .claimingSeat, error: .malformedPayload
            )
            return
        }
        await performGameAction(id, kind: .claimingSeat, attempt: attempt) {
            try await self.gameLifecycleService.claimSeat(
                ClaimSeatRequest(investigatorId: investigatorId), in: id, on: attempt.profile,
                token: token
            )
        } onSuccess: {
            // The claimed seat's open-seats snapshot is now stale; cleared rather than
            // reloaded eagerly so a lobby sheet that isn't currently showing it doesn't
            // pay for an unrequested reload.
            self.gameOpenSeats[id] = nil
            self.refreshGames()
        }
    }

    // MARK: - Choose deck

    /// Continues without upgrading a claimed seat's deck (``ChooseDeckRequest`` with
    /// no deck source) for `rawInvestigatorId` (an already-claimed seat's
    /// investigator, as reported by the game's own `investigators` summary) in `id`,
    /// and refreshes the games list on success.
    ///
    /// This slice never browses or upgrades a deck from a catalog/deck-list source;
    /// see ``ChooseDeckRequest`` and this type's own documentation.
    func continueWithoutUpgrading(investigatorId rawInvestigatorId: String, in id: GameID) {
        guard let attempt = beginGameAction(id, kind: .choosingDeck) else { return }
        gameLifecycleActionTasks[id] = Task { [weak self] in
            await self?.performChooseDeck(rawInvestigatorId, in: id, attempt: attempt)
        }
    }

    private func performChooseDeck(
        _ rawInvestigatorId: String, in id: GameID, attempt: GameActionAttempt
    ) async {
        guard let token = await resolveGameActionToken(id, kind: .choosingDeck, attempt: attempt)
        else { return }
        guard let investigatorId = try? InvestigatorCode(rawInvestigatorId) else {
            recordGameActionFailure(
                id, attempt: attempt, kind: .choosingDeck, error: .malformedPayload
            )
            return
        }
        let request = ChooseDeckRequest(investigatorId: investigatorId, deckUrl: nil, deckList: nil)
        await performGameAction(id, kind: .choosingDeck, attempt: attempt) {
            try await self.gameLifecycleService.chooseDeck(
                request, in: id, on: attempt.profile, token: token
            )
        } onSuccess: {
            self.refreshGames()
        }
    }
}
