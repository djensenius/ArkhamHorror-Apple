import Foundation

/// Web-compatible multiplayer invite operations for ``AppModel``.
struct GameInviteSessionToken: Equatable, Sendable {
    let profileID: UUID
    let generation: Int
    let credentialEpoch: Int
    let globalEpoch: Int
}

struct ClaimSeatInviteDetails: Equatable, Sendable {
    let gameID: GameID
    let seats: OpenSeats
    let playerCount: Int
    let viewerHasSeat: Bool
    let sessionToken: GameInviteSessionToken

    var showsClaimButtons: Bool {
        !viewerHasSeat && !seats.isEmpty
    }

    var canContinue: Bool {
        viewerHasSeat && seats.isEmpty
    }
}

private struct GameInviteSession: Sendable {
    let profile: ServerProfile
    let generation: Int
    let credentialEpoch: Int
    let globalEpoch: Int

    var token: GameInviteSessionToken {
        GameInviteSessionToken(
            profileID: profile.id,
            generation: generation,
            credentialEpoch: credentialEpoch,
            globalEpoch: globalEpoch
        )
    }
}

extension AppModel {
    /// Verifies and joins a web-shared pending-game invite through the same
    /// server-owned lifecycle sequence the web client uses for `/join`: `GET /join`
    /// first, then `PUT /join`, followed by a completed games-list refresh. The
    /// returned id comes from the server's join response; a mismatched or unsupported
    /// envelope is treated as contract drift rather than guessed at locally.
    ///
    /// - Throws: ``GameLifecycleError``, or rethrows `CancellationError`.
    @discardableResult
    func joinGameFromInvite(_ id: GameID) async throws -> GameID {
        let inviteSession = try currentGameInviteSession()
        let token = try await currentGameInviteToken(for: inviteSession)
        do {
            let preview = try await gameLifecycleService.peekLobby(
                id, on: inviteSession.profile, token: token
            )
            guard preview.id == id else { throw GameLifecycleError.malformedPayload }
            try ensureCurrentGameInviteSession(inviteSession)
            gameLobbyPlayerCounts[id] = preview.playerCount
            let joined = try await gameLifecycleService.joinGame(
                id, on: inviteSession.profile, token: token
            )
            guard case let .game(joinedID) = joined, joinedID == id else {
                throw GameLifecycleError.malformedPayload
            }
            try await refreshGamesForInvite(inviteSession, targetGameID: joinedID)
            reloadLobbyViewerSeatStatus(for: joinedID)
            return joinedID
        } catch let error as GameLifecycleError {
            await handleGameInviteLifecycleError(error, session: inviteSession)
            throw error
        }
    }

    /// Loads the claim-seat invite surface through the web sequence for
    /// `/claim-seat`: `GET /join` for display/authorization, then `GET /open-seats`.
    /// It deliberately never calls `PUT /join`; claiming is a separate explicit seat
    /// choice sent through ``claimSeatFromInvite(_:using:)``.
    func loadClaimSeatInvite(_ id: GameID) async throws -> ClaimSeatInviteDetails {
        let inviteSession = try currentGameInviteSession()
        let token = try await currentGameInviteToken(for: inviteSession)
        do {
            let preview = try await gameLifecycleService.peekLobby(
                id, on: inviteSession.profile, token: token
            )
            guard preview.id == id else { throw GameLifecycleError.malformedPayload }
            try ensureCurrentGameInviteSession(inviteSession)
            gameLobbyPlayerCounts[id] = preview.playerCount
            let seats = try await gameLifecycleService.openSeats(
                for: id, on: inviteSession.profile, token: token
            )
            try ensureCurrentGameInviteSession(inviteSession)
            let fullGame = try await getClaimSeatViewerSnapshot(
                id,
                session: inviteSession,
                token: token
            )
            try ensureCurrentGameInviteSession(inviteSession)
            return ClaimSeatInviteDetails(
                gameID: id,
                seats: seats,
                playerCount: fullGame?.game.playerCount ?? preview.playerCount,
                viewerHasSeat: fullGame?.playerID != nil,
                sessionToken: inviteSession.token
            )
        } catch let error as GameLifecycleError {
            await handleGameInviteLifecycleError(error, session: inviteSession)
            throw error
        }
    }

    /// Claims an explicit open seat from a `/claim-seat` invite and waits for the
    /// games-list refresh before returning, so presenting the lobby cannot flash a
    /// stale "game unavailable" state while the joined game is still loading.
    @discardableResult
    func claimSeatFromInvite(
        _ seat: CardCode,
        using details: ClaimSeatInviteDetails
    ) async throws -> GameID {
        let inviteSession = try currentGameInviteSession()
        try ensureCurrentGameInviteSession(inviteSession, matches: details.sessionToken)
        let token = try await currentGameInviteToken(for: inviteSession)
        guard let investigatorId = try? InvestigatorCode(openSeat: seat) else {
            throw GameLifecycleError.malformedPayload
        }
        do {
            try await gameLifecycleService.claimSeat(
                ClaimSeatRequest(investigatorId: investigatorId),
                in: details.gameID,
                on: inviteSession.profile,
                token: token
            )
            try await refreshGamesForInvite(inviteSession, targetGameID: details.gameID)
            reloadLobbyViewerSeatStatus(for: details.gameID)
            return details.gameID
        } catch let error as GameLifecycleError {
            try ensureCurrentGameInviteSession(inviteSession)
            await handleGameInviteLifecycleError(error, session: inviteSession)
            try ensureCurrentGameInviteSession(inviteSession)
            throw error
        }
    }

    /// Refreshes the games list for an already-seated `/claim-seat` invite before
    /// handing off to the lobby. This never calls `PUT /join`; the loaded invite's
    /// session token is the authority for whether the Continue action is still fresh.
    @discardableResult
    func continueClaimSeatInvite(using details: ClaimSeatInviteDetails) async throws -> GameID {
        let inviteSession = try currentGameInviteSession()
        try ensureCurrentGameInviteSession(inviteSession, matches: details.sessionToken)
        try await refreshGamesForInvite(inviteSession, targetGameID: details.gameID)
        return details.gameID
    }

    func reloadLobbyViewerSeatStatus(for id: GameID) {
        gameLobbyViewerHasSeats[id] = nil
        gameLobbyViewerSeatFailures[id] = nil
        gameLobbyDetailTasks[id]?.cancel()
        gameLobbyDetailTasks[id] = nil
        gameLobbyDetailTaskIDs[id] = nil
        loadLobbyDetailsIfNeeded(for: id)
    }

    func loadLobbyDetailsIfNeeded(for id: GameID) {
        guard gameLobbyDetailTasks[id] == nil,
              case let .signedIn(profile, _, _) = sessionState
        else { return }
        gameLobbyViewerHasSeats[id] = nil
        gameLobbyViewerSeatFailures[id] = nil
        let session = GameInviteSession(
            profile: profile,
            generation: generation,
            credentialEpoch: currentCredentialEpoch(for: profile.id),
            globalEpoch: currentGlobalCredentialEpoch()
        )
        let taskID = UUID()
        gameLobbyDetailTaskIDs[id] = taskID
        gameLobbyDetailTasks[id] = Task { [weak self] in
            await self?.performLoadLobbyDetails(for: id, session: session, taskID: taskID)
        }
    }

    private func performLoadLobbyDetails(
        for id: GameID,
        session: GameInviteSession,
        taskID: UUID
    ) async {
        defer { clearLobbyDetailTaskIfCurrent(for: id, taskID: taskID) }
        let token: String
        do {
            token = try await currentGameInviteToken(for: session)
            let envelope = try await gameLifecycleService.getGame(
                id, on: session.profile, token: token
            )
            try ensureCurrentGameInviteSession(session)
            gameLobbyPlayerCounts[id] = envelope.game.playerCount
            gameLobbyViewerHasSeats[id] = envelope.playerID != nil
            gameLobbyViewerSeatFailures[id] = nil
        } catch is CancellationError {
            return
        } catch GameLifecycleError.unexpectedStatus(404) {
            guard (try? ensureCurrentGameInviteSession(session)) != nil else { return }
            gameLobbyViewerHasSeats[id] = false
            gameLobbyViewerSeatFailures[id] = nil
        } catch let error as GameLifecycleError {
            guard (try? ensureCurrentGameInviteSession(session)) != nil else { return }
            gameLobbyViewerHasSeats[id] = nil
            gameLobbyViewerSeatFailures[id] = error
            await handleGameInviteLifecycleError(error, session: session)
        } catch {
            guard (try? ensureCurrentGameInviteSession(session)) != nil else { return }
            gameLobbyViewerHasSeats[id] = nil
            gameLobbyViewerSeatFailures[id] = .transportFailure("Lobby membership unavailable")
        }
    }

    private func clearLobbyDetailTaskIfCurrent(for id: GameID, taskID: UUID) {
        guard gameLobbyDetailTaskIDs[id] == taskID else { return }
        gameLobbyDetailTasks[id] = nil
        gameLobbyDetailTaskIDs[id] = nil
    }

    private func getClaimSeatViewerSnapshot(
        _ id: GameID,
        session: GameInviteSession,
        token: String
    ) async throws -> GetGameEnvelope? {
        do {
            let envelope = try await gameLifecycleService.getGame(
                id, on: session.profile, token: token
            )
            try ensureCurrentGameInviteSession(session)
            gameLobbyPlayerCounts[id] = envelope.game.playerCount
            gameLobbyViewerHasSeats[id] = envelope.playerID != nil
            gameLobbyViewerSeatFailures[id] = nil
            return envelope
        } catch GameLifecycleError.unexpectedStatus(404) {
            try ensureCurrentGameInviteSession(session)
            gameLobbyViewerHasSeats[id] = false
            gameLobbyViewerSeatFailures[id] = nil
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }
    }

    private func currentGameInviteSession() throws -> GameInviteSession {
        guard case let .signedIn(profile, _, _) = sessionState else {
            throw GameLifecycleError.sessionExpired
        }
        return GameInviteSession(
            profile: profile,
            generation: generation,
            credentialEpoch: currentCredentialEpoch(for: profile.id),
            globalEpoch: currentGlobalCredentialEpoch()
        )
    }

    private func currentGameInviteToken(for session: GameInviteSession) async throws -> String {
        do {
            let token = try await currentGameLifecycleToken(for: session.profile)
            try ensureCurrentGameInviteSession(session)
            return token
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch GameLifecycleTokenAccessError.stale {
            throw CancellationError()
        } catch GameLifecycleTokenAccessError.noToken {
            try ensureCurrentGameInviteSession(session)
            await handleGameInviteLifecycleError(.sessionExpired, session: session)
            try ensureCurrentGameInviteSession(session)
            throw GameLifecycleError.sessionExpired
        } catch GameLifecycleTokenAccessError.tokenStore {
            try ensureCurrentGameInviteSession(session)
            throw GameLifecycleError.tokenUnavailable
        }
    }

    private func ensureCurrentGameInviteSession(_ session: GameInviteSession) throws {
        guard isCurrent(session.generation),
              currentCredentialEpoch(for: session.profile.id) == session.credentialEpoch,
              currentGlobalCredentialEpoch() == session.globalEpoch,
              case let .signedIn(profile, _, _) = sessionState,
              profile.id == session.profile.id
        else { throw CancellationError() }
    }

    private func ensureCurrentGameInviteSession(
        _ session: GameInviteSession,
        matches token: GameInviteSessionToken
    ) throws {
        guard session.token == token else { throw CancellationError() }
        try ensureCurrentGameInviteSession(session)
    }

    private func refreshGamesForInvite(
        _ session: GameInviteSession,
        targetGameID: GameID
    ) async throws {
        try ensureCurrentGameInviteSession(session)
        refreshGames()
        let refreshGeneration = gameListGeneration
        let refreshTask = gameListTask
        await refreshTask?.value
        try ensureCurrentGameInviteSession(session)
        guard refreshGeneration == gameListGeneration else {
            throw GameLifecycleError.inviteRefreshFailed
        }
        guard case let .loaded(games) = gameListState,
              games.contains(where: { entry in
                  switch entry {
                  case let .game(summary):
                      summary.id == targetGameID
                  case .failed:
                      false
                  }
              })
        else {
            throw GameLifecycleError.inviteRefreshFailed
        }
    }

    private func handleGameInviteLifecycleError(
        _ error: GameLifecycleError,
        session: GameInviteSession
    ) async {
        guard case .sessionExpired = error, isCurrent(session.generation) else { return }
        await handleGameLifecycleSessionExpired(
            profile: session.profile,
            generation: session.generation,
            credentialEpoch: session.credentialEpoch,
            globalEpoch: session.globalEpoch
        )
    }
}
