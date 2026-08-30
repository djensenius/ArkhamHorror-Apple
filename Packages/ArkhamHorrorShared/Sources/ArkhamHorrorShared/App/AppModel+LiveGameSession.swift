import Foundation

/// The profile, generation, and credential/global-epoch snapshot captured when a
/// live-game session starts (``AppModel/startLiveGameSession(_:)``), threaded through
/// its entire async body. Mirrors ``AppModel/GameActionAttempt``'s (private,
/// `AppModel+GameLifecycleActions.swift`) shape and purpose exactly, scoped to a
/// live-game session instead of a one-shot lifecycle action: a small named type
/// (rather than a multi-parameter/tuple signature) keeps every function below within
/// this project's tuple-arity/line-length conventions.
struct LiveGameSessionAttempt: Sendable {
    let gameID: GameID
    let profile: ServerProfile
    let attemptID: UUID
    let sessionGeneration: Int
    let credentialEpoch: Int
    let globalEpoch: Int
}

/// The result of ``AppModel/consumeLiveGameSocket(_:connection:projection:)``'s
/// receive loop. `Equatable` (via `BoardProjection`'s own conformance) purely so
/// deterministic tests can assert an exact outcome directly.
enum LiveGameSocketConsumeOutcome: Equatable {
    /// The loop ended because this session was cancelled/superseded, or because it
    /// already published a terminal, non-reconnectable state (an incompatible
    /// payload) itself. The caller must simply stop; nothing further to publish.
    case stopped
    /// The connection was lost (network loss) or closed (clean closing handshake --
    /// treated identically; see ``GameSocketEvent/closed(code:reason:)``) and
    /// reconnect-with-backoff should be attempted, carrying the last known-good
    /// projection forward so the board stays visible through the reconnect.
    case lost(BoardProjection)
}

/// The live-game session runner: REST snapshot fetch, WebSocket connect/consume, and
/// bounded-backoff reconnect, bound to `AppModel`'s existing single session/token
/// authority exactly like every other game-lifecycle operation (see
/// `AppModel+GameLifecycle.swift`/`AppModel+GameLifecycleActions.swift`, whose
/// per-operation "attempt" + generation/epoch staleness-recheck pattern this file
/// mirrors precisely, scoped per ``GameID`` via ``AppModel/liveGameSessions`` instead
/// of ``AppModel/gameLifecycleActionAttempts``).
///
/// ## Reconnect ordering
///
/// The *very first* connection for a session fetches the authoritative REST snapshot
/// and publishes it before ever opening a socket (fast time-to-first-paint; see
/// ``fetchLiveGameProjection(_:)``'s call in ``runLiveGameSession(_:)``). Every
/// *subsequent* connection (after a loss) instead opens the new socket **before**
/// performing the REST refetch, and only begins actually consuming frames from it
/// once that refetch has been published: opening the socket first guarantees any
/// update the backend broadcasts from that instant forward is queued for this
/// client to eventually receive (the OS/TCP layer buffers messages sent to an
/// established-but-not-yet-``receive()``-ing socket; nothing is lost merely because
/// this client has not called `receive()` yet), so the refetched REST snapshot can
/// never be older than the socket's own subscription instant. Refetching *before*
/// opening the new socket instead would leave exactly the opposite, unrecoverable
/// gap: an update broadcast after the refetch but before the new socket subscribes
/// would never reach either the (already-returned) REST response or the
/// (not-yet-subscribed) socket, permanently stalling the board until the game's next
/// unrelated update happened to arrive. This is the "race-safe order that cannot
/// lose authority" this session runner is required to preserve.
///
/// ## Backpressure and cancellation
///
/// Exactly one ``GameSocketConnection`` is open, and exactly one
/// ``GameSocketConnection/nextEvent()`` call is in flight, at any moment for a given
/// session (see ``consumeLiveGameSocket(_:connection:projection:)``'s single
/// `while` loop) -- there is no recursive/concurrent receive accumulation and no
/// detached task anywhere in this file; every `Task` this session ever creates is
/// the one owned by ``AppModel/liveGameSessions``, awaited implicitly by this
/// session's own sequential control flow rather than fired-and-forgotten. Every
/// `await` (token resolution, REST fetch, socket connect, socket receive, backoff
/// sleep) is followed by an ``isCurrentLiveGameSession(_:)`` recheck before any
/// state mutation, so a stale/superseded session (cancelled by
/// ``AppModel/stopLiveGameSession(_:)`` or replaced by a newer attempt via
/// ``AppModel/startLiveGameSession(_:)``) can never publish state, and an older
/// frame can never overwrite a newer generation's.
extension AppModel {
    func isCurrentLiveGameSession(_ attempt: LiveGameSessionAttempt) -> Bool {
        isCurrent(attempt.sessionGeneration)
            && liveGameSessions[attempt.gameID]?.attemptID == attempt.attemptID
    }

    // MARK: - Session lifecycle

    /// Starts (or restarts, for an explicit ``AppModel/retryLiveGame(_:)``) `id`'s
    /// live session: cancels any previous task for `id` (its stale completions are
    /// then guaranteed to fail ``isCurrentLiveGameSession(_:)`` against the new
    /// attempt identity installed below, so this never needs to await that old
    /// task's teardown first), captures a fresh attempt identity/generation/epoch
    /// snapshot, publishes ``LiveGameState/loading``, and launches the runner task.
    ///
    /// A no-op transition to ``LiveGameState/authenticationExpired`` (no task
    /// started at all) when not currently signed in, exactly matching how every
    /// other authenticated surface in this package behaves outside a signed-in
    /// session.
    func startLiveGameSession(_ id: GameID) {
        liveGameSessions[id]?.task.cancel()
        guard case let .signedIn(profile, _, _) = sessionState else {
            liveGameSessions[id] = nil
            liveGameStates[id] = .authenticationExpired
            return
        }
        let attempt = LiveGameSessionAttempt(
            gameID: id,
            profile: profile,
            attemptID: UUID(),
            sessionGeneration: generation,
            credentialEpoch: currentCredentialEpoch(for: profile.id),
            globalEpoch: currentGlobalCredentialEpoch()
        )
        liveGameStates[id] = .loading
        let task = Task<Void, Never> { [weak self] in
            await self?.runLiveGameSession(attempt)
        }
        liveGameSessions[id] = LiveGameSessionHandle(attemptID: attempt.attemptID, task: task)
    }

    /// Cancels `id`'s live session task (if any) and clears its session/state
    /// entries entirely, so a torn-down game with no remaining viewer leaves
    /// nothing behind in ``AppModel/liveGameSessions``/``AppModel/liveGameStates``.
    /// Idempotent.
    func stopLiveGameSession(_ id: GameID) {
        liveGameSessions[id]?.task.cancel()
        liveGameSessions[id] = nil
        liveGameStates[id] = nil
    }

    // MARK: - Runner

    private func runLiveGameSession(_ attempt: LiveGameSessionAttempt) async {
        guard var projection = await fetchLiveGameProjection(attempt) else { return }
        var reconnectAttempt = 0
        var needsRefetchBeforeConsuming = false

        while true {
            guard isCurrentLiveGameSession(attempt) else { return }
            guard let connection = await connectLiveGameSocketRetrying(
                attempt, reconnectAttempt: &reconnectAttempt
            ) else { return }

            if needsRefetchBeforeConsuming {
                guard let refreshed = await fetchLiveGameProjection(attempt) else {
                    connection.close(code: .goingAway, reason: nil)
                    return
                }
                projection = refreshed
            }
            reconnectAttempt = 0

            let outcome = await consumeLiveGameSocket(
                attempt, connection: connection, projection: projection
            )
            switch outcome {
            case .stopped:
                return
            case let .lost(lastKnown):
                projection = lastKnown
                guard isCurrentLiveGameSession(attempt) else { return }
                liveGameStates[attempt.gameID] = .reconnecting(lastKnown: projection)
                guard await performReconnectBackoff(attempt, reconnectAttempt: &reconnectAttempt)
                else { return }
                needsRefetchBeforeConsuming = true
            }
        }
    }

    /// Attempts to open this session's socket, retrying every transient
    /// (``GameSocketConnectError/transport``) connect failure with backoff --
    /// via ``handleLiveGameSocketConnectFailure(_:error:reconnectAttempt:)`` -- until
    /// it succeeds, this session becomes stale, or a non-retryable connect failure
    /// (already published by that same call) ends the loop. Returns `nil` exactly
    /// when the caller must simply stop; the terminating condition has always
    /// already been fully handled (published, or a no-op stale/cancelled session).
    private func connectLiveGameSocketRetrying(
        _ attempt: LiveGameSessionAttempt, reconnectAttempt: inout Int
    ) async -> (any GameSocketConnection)? {
        while true {
            guard isCurrentLiveGameSession(attempt) else { return nil }
            do {
                return try await connectLiveGameSocket(attempt)
            } catch is CancellationError {
                return nil
            } catch let connectError as GameSocketConnectError {
                guard await handleLiveGameSocketConnectFailure(
                    attempt, error: connectError, reconnectAttempt: &reconnectAttempt
                ) else { return nil }
            } catch {
                // Unreachable: `GameSocketFactory.connect(to:)` only ever throws
                // `GameSocketConnectError` or rethrows `CancellationError` (see its
                // documentation); handled defensively rather than force-cast.
                return nil
            }
        }
    }

    // MARK: - Token resolution

    /// Resolves this session's bearer token through
    /// ``AppModel/currentGameLifecycleToken(for:)`` -- the same serialized,
    /// epoch-guarded path every other authenticated operation in this package uses.
    /// Publishes a typed terminal state (and, for a durably-missing token, routes
    /// through session-expiry exactly like an explicit 401) on every non-stale
    /// failure; returns `nil` on any failure or staleness, mirroring
    /// ``resolveGameActionToken(_:kind:attempt:)``'s (private,
    /// `AppModel+GameLifecycleActions.swift`) shape exactly.
    func resolveLiveGameToken(_ attempt: LiveGameSessionAttempt) async -> String? {
        do {
            return try await currentGameLifecycleToken(for: attempt.profile)
        } catch is CancellationError {
            return nil
        } catch let tokenError as GameLifecycleTokenAccessError {
            guard isCurrentLiveGameSession(attempt) else { return nil }
            switch tokenError {
            case .stale:
                break
            case .noToken:
                liveGameStates[attempt.gameID] = .authenticationExpired
                await handleGameLifecycleSessionExpired(
                    profile: attempt.profile,
                    generation: attempt.sessionGeneration,
                    credentialEpoch: attempt.credentialEpoch,
                    globalEpoch: attempt.globalEpoch
                )
            case .tokenStore:
                let lastKnown = liveGameStates[attempt.gameID]?.lastKnownProjection
                liveGameStates[attempt.gameID] = .terminalFailure(
                    .tokenUnavailable, lastKnown: lastKnown
                )
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - REST fetch

    /// Resolves a token and fetches+publishes `attempt.gameID`'s current
    /// authoritative snapshot via ``GameLifecycleServicing/getGame(_:on:token:)`` --
    /// the exact same ``ContractJSON``/``GetGameEnvelope`` boundary a WebSocket
    /// frame's snapshot payload also decodes through (see ``fetchLiveGameProjection(_:)``
    /// 's call sites for why the *order* relative to the socket differs between the
    /// first fetch and every subsequent reconnect refetch, even though this
    /// function's own body is identical either way) -- through
    /// ``BoardProjectionBuilder``, publishing ``LiveGameState/live(_:)`` on success.
    ///
    /// Returns the published projection on success, or `nil` on any failure,
    /// staleness, or cancellation (having already published whatever typed state --
    /// ``LiveGameState/authenticationExpired``, ``LiveGameState/offline(lastKnown:)``,
    /// ``LiveGameState/incompatiblePayload(lastKnown:)``, or
    /// ``LiveGameState/terminalFailure(_:lastKnown:)`` -- that failure warrants, if
    /// this attempt is still current).
    private func fetchLiveGameProjection(
        _ attempt: LiveGameSessionAttempt
    ) async -> BoardProjection? {
        guard let token = await resolveLiveGameToken(attempt) else { return nil }
        do {
            let envelope = try await gameLifecycleService.getGame(
                attempt.gameID, on: attempt.profile, token: token
            )
            try Task.checkCancellation()
            let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
            guard isCurrentLiveGameSession(attempt) else { return nil }
            liveGameStates[attempt.gameID] = .live(projection)
            return projection
        } catch is CancellationError {
            return nil
        } catch let error as GameLifecycleError {
            guard isCurrentLiveGameSession(attempt) else { return nil }
            let lastKnown = liveGameStates[attempt.gameID]?.lastKnownProjection
            liveGameStates[attempt.gameID] = Self.liveGameFetchFailureState(
                for: error, lastKnown: lastKnown
            )
            if case .sessionExpired = error {
                await handleGameLifecycleSessionExpired(
                    profile: attempt.profile,
                    generation: attempt.sessionGeneration,
                    credentialEpoch: attempt.credentialEpoch,
                    globalEpoch: attempt.globalEpoch
                )
            }
            return nil
        } catch {
            guard isCurrentLiveGameSession(attempt) else { return nil }
            let lastKnown = liveGameStates[attempt.gameID]?.lastKnownProjection
            liveGameStates[attempt.gameID] = .terminalFailure(
                .transportFailure("Unexpected live-game fetch failure."), lastKnown: lastKnown
            )
            return nil
        }
    }

    /// Pure mapping from a REST fetch's ``GameLifecycleError`` to the
    /// ``LiveGameState`` it publishes -- factored out of
    /// ``fetchLiveGameProjection(_:)`` so that function's own cyclomatic complexity
    /// stays low and this classification is independently testable. Does not itself
    /// perform ``sessionExpired``'s session-expiry side effect (see
    /// `AppModel.handleGameLifecycleSessionExpired`); the caller performs that
    /// separately after publishing this state.
    private static func liveGameFetchFailureState(
        for error: GameLifecycleError, lastKnown: BoardProjection?
    ) -> LiveGameState {
        switch error {
        case .sessionExpired:
            .authenticationExpired
        case .transportFailure, .nonHTTPResponse:
            .offline(lastKnown: lastKnown)
        case .malformedPayload:
            .incompatiblePayload(lastKnown: lastKnown)
        case .unexpectedStatus, .requestEncodingFailed, .invalidPathSegment, .tokenUnavailable:
            .terminalFailure(error, lastKnown: lastKnown)
        }
    }
}
