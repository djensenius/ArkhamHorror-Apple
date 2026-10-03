/// Web-compatible multiplayer invite operations for ``AppModel``.
private struct GameInviteSession: Sendable {
    let profile: ServerProfile
    let generation: Int
    let credentialEpoch: Int
    let globalEpoch: Int
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
            guard preview == .game(id) else { throw GameLifecycleError.malformedPayload }
            try ensureCurrentGameInviteSession(inviteSession)
            let joined = try await gameLifecycleService.joinGame(
                id, on: inviteSession.profile, token: token
            )
            guard case let .game(joinedID) = joined else {
                throw GameLifecycleError.malformedPayload
            }
            try await refreshGamesForInvite(inviteSession)
            return joinedID
        } catch let error as GameLifecycleError {
            await handleGameInviteLifecycleError(error, session: inviteSession)
            throw error
        }
    }

    /// Loads the claim-seat invite surface through the web sequence for
    /// `/claim-seat`: `GET /join` for display/authorization, then `GET /open-seats`.
    /// It deliberately never calls `PUT /join`; claiming is a separate explicit seat
    /// choice sent through ``claimSeatFromInvite(_:in:)``.
    func loadClaimSeatInvite(_ id: GameID) async throws -> OpenSeats {
        let inviteSession = try currentGameInviteSession()
        let token = try await currentGameInviteToken(for: inviteSession)
        do {
            let preview = try await gameLifecycleService.peekLobby(
                id, on: inviteSession.profile, token: token
            )
            guard preview == .game(id) else { throw GameLifecycleError.malformedPayload }
            try ensureCurrentGameInviteSession(inviteSession)
            let seats = try await gameLifecycleService.openSeats(
                for: id, on: inviteSession.profile, token: token
            )
            try ensureCurrentGameInviteSession(inviteSession)
            return seats
        } catch let error as GameLifecycleError {
            await handleGameInviteLifecycleError(error, session: inviteSession)
            throw error
        }
    }

    /// Claims an explicit open seat from a `/claim-seat` invite and waits for the
    /// games-list refresh before returning, so presenting the lobby cannot flash a
    /// stale "game unavailable" state while the joined game is still loading.
    @discardableResult
    func claimSeatFromInvite(_ seat: CardCode, in id: GameID) async throws -> GameID {
        let inviteSession = try currentGameInviteSession()
        let token = try await currentGameInviteToken(for: inviteSession)
        guard let investigatorId = try? InvestigatorCode(openSeat: seat) else {
            throw GameLifecycleError.malformedPayload
        }
        do {
            try await gameLifecycleService.claimSeat(
                ClaimSeatRequest(investigatorId: investigatorId),
                in: id,
                on: inviteSession.profile,
                token: token
            )
            try await refreshGamesForInvite(inviteSession)
            return id
        } catch let error as GameLifecycleError {
            await handleGameInviteLifecycleError(error, session: inviteSession)
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
            return try await currentGameLifecycleToken(for: session.profile)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch GameLifecycleTokenAccessError.stale {
            throw CancellationError()
        } catch GameLifecycleTokenAccessError.noToken {
            throw GameLifecycleError.sessionExpired
        } catch GameLifecycleTokenAccessError.tokenStore {
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

    private func refreshGamesForInvite(_ session: GameInviteSession) async throws {
        try ensureCurrentGameInviteSession(session)
        refreshGames()
        let refreshTask = gameListTask
        await refreshTask?.value
        try ensureCurrentGameInviteSession(session)
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
