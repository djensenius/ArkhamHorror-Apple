import Foundation

/// The live-game session's socket connect/reconnect-backoff/consume implementation --
/// split out of `AppModel+LiveGameSession.swift` purely to stay under this project's
/// per-file line-length convention; conceptually still part of that same session
/// runner (see its documentation for the full reconnect-ordering/backpressure/
/// cancellation design this file implements).
extension AppModel {
    /// The intermediary-proxy HTTP statuses a pre-upgrade WebSocket handshake
    /// failure is treated as transient/retryable for, rather than a permanent
    /// terminal rejection: Bad Gateway, Service Unavailable, and Gateway Timeout --
    /// the standard statuses a reverse proxy/load balancer in front of the actual
    /// game server returns when *it* (not the application) could not complete the
    /// upgrade, distinct from any status the application's own authorization logic
    /// would ever produce.
    static let transientIntermediaryStatuses: Set<Int> = [502, 503, 504]

    // MARK: - Socket connect

    /// Resolves a token and opens a new WebSocket connection to
    /// ``LiveGameEndpoint/webSocketURL(for:on:token:pin:)``.
    ///
    /// - Throws: `CancellationError` when this attempt is stale, cancelled, or a
    ///   (practically unreachable, since every ``GameID`` is a `UUID`) URL
    ///   construction failure already published a terminal state -- the same
    ///   "convert an already-handled condition into `CancellationError` so the
    ///   caller's single `catch is CancellationError` uniformly means 'already
    ///   handled, just stop'" idiom ``createGame(_:)``
    ///   (`AppModel+GameLifecycle.swift`) uses -- or rethrows
    ///   ``GameSocketConnectError`` from ``GameSocketFactory/connect(to:)``.
    func connectLiveGameSocket(
        _ attempt: LiveGameSessionAttempt
    ) async throws -> any GameSocketConnection {
        guard let token = await resolveLiveGameToken(attempt) else {
            throw CancellationError()
        }
        let url: URL
        do {
            url = try LiveGameEndpoint.webSocketURL(
                for: attempt.gameID, on: attempt.profile, token: token
            )
        } catch let error as GameLifecycleError {
            guard isCurrentLiveGameSession(attempt) else { throw CancellationError() }
            let lastKnown = liveGameStates[attempt.gameID]?.lastKnownProjection
            liveGameStates[attempt.gameID] = .terminalFailure(error, lastKnown: lastKnown)
            throw CancellationError()
        }
        return try await liveGameSocketFactory.connect(to: url)
    }

    /// Publishes the outcome of a failed ``connectLiveGameSocket(_:)`` call and
    /// reports whether the runner loop should retry (`true`, after this function's
    /// own backoff delay already elapsed) or stop entirely (`false`).
    ///
    /// A `401` is classified explicitly (per this backend's documented
    /// pre-upgrade-`401`-instead-of-a-WebSocket-close-code behavior -- see
    /// ``GameSocketConnectError/http(status:)``) and routed through session-expiry
    /// exactly like an explicit REST 401, never retried. `502`/`503`/`504` (Bad
    /// Gateway/Service Unavailable/Gateway Timeout) are the standard, well-defined
    /// HTTP statuses an intermediary reverse proxy/load balancer returns for a
    /// transient upstream/handshake condition -- never something this application's
    /// own token/authorization logic produced -- so they are treated exactly like
    /// ``GameSocketConnectError/transport`` and retried with backoff rather than
    /// treated as a permanent rejection. Every other HTTP status is treated as a
    /// genuine application-level rejection (not a transient network condition) and
    /// reported as a non-retryable ``LiveGameState/terminalFailure(_:lastKnown:)``.
    func handleLiveGameSocketConnectFailure(
        _ attempt: LiveGameSessionAttempt,
        error: GameSocketConnectError,
        reconnectAttempt: inout Int
    ) async -> Bool {
        guard isCurrentLiveGameSession(attempt) else { return false }
        let lastKnown = liveGameStates[attempt.gameID]?.lastKnownProjection
        switch error {
        case let .http(status) where status == 401:
            liveGameStates[attempt.gameID] = .authenticationExpired
            await handleGameLifecycleSessionExpired(
                profile: attempt.profile,
                generation: attempt.sessionGeneration,
                credentialEpoch: attempt.credentialEpoch,
                globalEpoch: attempt.globalEpoch
            )
            return false
        case let .http(status) where Self.transientIntermediaryStatuses.contains(status):
            liveGameStates[attempt.gameID] = .reconnecting(lastKnown: lastKnown)
            return await performReconnectBackoff(attempt, reconnectAttempt: &reconnectAttempt)
        case let .http(status):
            liveGameStates[attempt.gameID] = .terminalFailure(
                .unexpectedStatus(status), lastKnown: lastKnown
            )
            return false
        case .transport:
            liveGameStates[attempt.gameID] = .reconnecting(lastKnown: lastKnown)
            return await performReconnectBackoff(attempt, reconnectAttempt: &reconnectAttempt)
        }
    }

    // MARK: - Reconnect backoff

    /// Sleeps for this attempt's bounded, jittered backoff delay
    /// (``LiveGameReconnectPolicy``), then reports whether the runner loop should
    /// continue (`true`) or stop (`false`, either because the attempt budget was
    /// already exhausted -- publishing ``LiveGameState/offline(lastKnown:)``, this
    /// session's *only* remaining path back to `.live` being an explicit
    /// ``AppModel/retryLiveGame(_:)`` call, so this can never become an unbounded
    /// retry storm -- or because sleeping itself was cancelled).
    func performReconnectBackoff(
        _ attempt: LiveGameSessionAttempt, reconnectAttempt: inout Int
    ) async -> Bool {
        guard isCurrentLiveGameSession(attempt) else { return false }
        guard reconnectAttempt < LiveGameReconnectPolicy.maximumAttempts else {
            let lastKnown = liveGameStates[attempt.gameID]?.lastKnownProjection
            liveGameStates[attempt.gameID] = .offline(lastKnown: lastKnown)
            return false
        }
        let unitInterval = liveGameRandomSource.nextUnitInterval()
        let delay = LiveGameReconnectPolicy.jitteredDelay(
            forAttempt: reconnectAttempt, unitInterval: unitInterval
        )
        reconnectAttempt += 1
        do {
            try await liveGameClock.sleep(for: delay)
        } catch {
            return false
        }
        return isCurrentLiveGameSession(attempt)
    }

    // MARK: - Socket consume

    /// Serially receives, decodes, and publishes frames from `connection` until it
    /// closes/is lost, an incompatible payload is decoded, or this session is
    /// cancelled/superseded -- exactly one ``GameSocketConnection/nextEvent()`` call
    /// in flight at a time, never concurrently. `connection.close(code:reason:)` is
    /// called exactly once on every exit path (each call site below is mutually
    /// exclusive with every other), so this connection can never be left open, and
    /// is always closed at most once per generation, matching this method's own
    /// idempotent-close guarantee defensively rather than relying on it.
    ///
    /// A `.snapshot` frame decodes through the exact same ``BoardProjectionBuilder``
    /// a REST fetch's ``PublicGameSnapshot`` does, publishing
    /// ``LiveGameState/live(_:)``. An `.unsupportedMessage` frame (any
    /// `ServerMessage` tag besides `GameUpdate`; see ``BoardSnapshotUpdate``'s own
    /// documentation) is silently ignored -- normal, expected, out-of-scope traffic
    /// this contract slice does not decode further, never treated as an
    /// incompatibility. Only an actual ``ContractJSON`` decode throw (malformed
    /// bytes/schema drift in what was supposed to be a `GameUpdate`) publishes
    /// ``LiveGameState/incompatiblePayload(lastKnown:)`` and returns
    /// ``LiveGameSocketConsumeOutcome/stopped`` (never retried by reconnecting: a
    /// decode failure is a genuine contract mismatch reconnecting cannot fix).
    func consumeLiveGameSocket(
        _ attempt: LiveGameSessionAttempt,
        connection: any GameSocketConnection,
        projection initialProjection: BoardProjection
    ) async -> LiveGameSocketConsumeOutcome {
        var projection = initialProjection
        while true {
            guard isCurrentLiveGameSession(attempt) else {
                connection.close(code: .goingAway, reason: nil)
                return .stopped
            }

            let event: GameSocketEvent
            do {
                // `withTaskCancellationHandler`'s `onCancel` fires synchronously
                // on cancellation (even if `connection.nextEvent()` is already
                // suspended mid-`receive()`), immediately closing the connection so
                // that in-flight receive is interrupted promptly rather than
                // blocking until some future frame or timeout.
                event = try await withTaskCancellationHandler {
                    try await connection.nextEvent()
                } onCancel: {
                    connection.close(code: .goingAway, reason: nil)
                }
            } catch {
                // A cancellation-triggered local close above is indistinguishable
                // from a genuine network loss purely from `nextEvent()`'s thrown
                // error; rechecking cancellation here -- the same idiom used
                // throughout this package's REST clients -- ensures a
                // cancelled/superseded session is always reported as `.stopped`,
                // never misreported as a reconnectable `.lost`.
                if Task.isCancelled || !isCurrentLiveGameSession(attempt) {
                    connection.close(code: .goingAway, reason: nil)
                    return .stopped
                }
                connection.close(code: .goingAway, reason: nil)
                return .lost(projection)
            }

            guard isCurrentLiveGameSession(attempt) else {
                connection.close(code: .goingAway, reason: nil)
                return .stopped
            }

            switch event {
            case let .message(data):
                let update: BoardSnapshotUpdate
                do {
                    update = try ContractJSON.decode(BoardSnapshotUpdate.self, from: data)
                } catch {
                    liveGameStates[attempt.gameID] = .incompatiblePayload(lastKnown: projection)
                    connection.close(code: .goingAway, reason: nil)
                    return .stopped
                }
                switch update {
                case let .snapshot(snapshot):
                    projection = BoardProjectionBuilder.makeProjection(from: snapshot)
                    liveGameStates[attempt.gameID] = .live(projection)
                case .unsupportedMessage:
                    continue
                }
            case .closed:
                connection.close(code: .goingAway, reason: nil)
                return .lost(projection)
            }
        }
    }
}
