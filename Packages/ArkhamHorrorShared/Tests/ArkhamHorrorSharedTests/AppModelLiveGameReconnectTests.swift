@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Continuation of `AppModelLiveGameTests.swift`, split purely to respect this
/// package's file/type-length lint limits: stale/cancelled attempt safety,
/// reconnect backoff bounds, socket connect failure classification, subscription
/// reference-counting, `retryLiveGame` semantics, and sign-out cancellation.
/// Shares the same fixtures/fakes/helpers declared in the primary file via this
/// `extension`.
extension AppModelLiveGameTests {
    // MARK: - Stale/cancelled attempts cannot publish

    @Test("A stale attempt's consumeLiveGameSocket call cannot publish state or overwrite it")
    func staleAttemptCannotPublishFromConsumeLoop() async throws {
        let (model, _) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        // Install a *different* (current) attempt/session, so the hand-built
        // `staleAttempt` below never matches `liveGameSessions[gameID]`.
        _ = installCurrentAttempt(for: gameID, on: model)
        let staleAttempt = LiveGameSessionAttempt(
            gameID: gameID,
            profile: .hosted,
            attemptID: UUID(),
            sessionGeneration: model.generation,
            credentialEpoch: model.currentCredentialEpoch(for: ServerProfile.hosted.id),
            globalEpoch: model.currentGlobalCredentialEpoch()
        )
        model.liveGameStates[gameID] = .loading
        let connection = FakeGameSocketConnection()
        let envelope = try loadGetGame()
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        let queuedUpdate = try loadGameUpdateData()
        await connection.enqueue(.event(.message(queuedUpdate)))

        let outcome = await model.consumeLiveGameSocket(
            staleAttempt, connection: connection, projection: projection
        )
        #expect(outcome == .stopped)
        // Untouched: still exactly the `.loading` this test set up before the stale
        // call, never overwritten by the stale attempt's own frame.
        #expect(model.liveGameState(for: gameID) == .loading)
        await connection.waitUntilClosed()
    }

    @Test("""
    A socket connect that resolves after the owning subscription is withdrawn is \
    immediately closed and never consumed, even though the factory call itself was \
    already in flight
    """)
    func connectResolvingAfterUnsubscribeIsDiscardedUnconsumed() async throws {
        // `connectLiveGameSocket` intentionally defers its currency recheck to the
        // point where the connection would actually be consumed (mirroring how
        // `fetchLiveGameProjection` performs its REST call before rechecking): the
        // safety net is `consumeLiveGameSocket`'s own guard, checked before it ever
        // calls `nextEvent()`. This test proves that guard holds even when the
        // resolved connection already has a frame queued up.
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let envelope = try loadGetGame()
        await fakes.service.enqueueGetGameResult(.success(envelope))
        await fakes.socketFactory.setGated(true)

        let token = model.subscribeToLiveGame(gameID)
        await fakes.socketFactory.waitUntilConnectPending(1)
        let task = try #require(model.liveGameSessions[gameID]?.task)

        // Withdraw the only viewer: this tears the session down and removes the
        // `liveGameSessions[gameID]` entry, making the in-flight attempt stale.
        model.unsubscribeFromLiveGame(token)
        #expect(model.liveGameSessions[gameID] == nil)

        // Only now resolve the gated connect -- with a connection that already has
        // a decodable frame waiting, so any accidental consumption would be visible.
        let staleConnection = FakeGameSocketConnection()
        let queuedUpdate = try loadGameUpdateData()
        await staleConnection.enqueue(.event(.message(queuedUpdate)))
        await fakes.socketFactory.resumeOldestConnect(with: .success(staleConnection))

        await task.value
        await staleConnection.waitUntilClosed()
        // Never overwritten by the stale connection's queued frame.
        #expect(model.liveGameState(for: gameID) == .idle)
    }

    @Test("A stale attempt's performReconnectBackoff returns false without sleeping/publishing")
    func staleAttemptSkipsBackoffEntirely() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let staleAttempt = LiveGameSessionAttempt(
            gameID: gameID,
            profile: .hosted,
            attemptID: UUID(),
            sessionGeneration: model.generation,
            credentialEpoch: model.currentCredentialEpoch(for: ServerProfile.hosted.id),
            globalEpoch: model.currentGlobalCredentialEpoch()
        )
        model.liveGameStates[gameID] = try .live(
            BoardProjectionBuilder.makeProjection(from: loadGetGame().game)
        )
        var reconnectAttempt = 0
        let shouldContinue = await model.performReconnectBackoff(
            staleAttempt, reconnectAttempt: &reconnectAttempt
        )
        #expect(!shouldContinue)
        let durations = await fakes.clock.requestedDurations
        #expect(durations.isEmpty)
    }

    // MARK: - Reconnect backoff bounds / no retry storm

    @Test("Reconnect backoff requests the exact jittered delay for each attempt, then goes offline")
    func reconnectBackoffExhaustsToOfflineWithExactJitteredDelays() async throws {
        let (model, fakes) = makeSignedInModel(randomValues: [0.5])
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = installCurrentAttempt(for: gameID, on: model)
        model.liveGameStates[gameID] = try .live(
            BoardProjectionBuilder.makeProjection(from: loadGetGame().game)
        )

        var reconnectAttempt = 0
        var continued = true
        var observedAttempts = 0
        while continued, observedAttempts < LiveGameReconnectPolicy.maximumAttempts + 1 {
            continued = await model.performReconnectBackoff(
                attempt, reconnectAttempt: &reconnectAttempt
            )
            observedAttempts += 1
        }
        // Exactly `maximumAttempts` sleeps were requested before giving up -- never
        // more, proving this can never become an unbounded retry storm.
        let durations = await fakes.clock.requestedDurations
        #expect(durations.count == LiveGameReconnectPolicy.maximumAttempts)
        for (index, duration) in durations.enumerated() {
            let expected = LiveGameReconnectPolicy.jitteredDelay(
                forAttempt: index, unitInterval: 0.5
            )
            #expect(duration == expected)
        }
        #expect(!continued)
        let expectedLastKnown = try BoardProjectionBuilder.makeProjection(from: loadGetGame().game)
        #expect(model.liveGameState(for: gameID) == .offline(lastKnown: expectedLastKnown))
    }

    @Test("A cancelled backoff sleep stops the loop without publishing offline")
    func cancelledBackoffSleepStopsWithoutPublishingOffline() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = installCurrentAttempt(for: gameID, on: model)
        let liveProjection = try BoardProjectionBuilder.makeProjection(from: loadGetGame().game)
        model.liveGameStates[gameID] = .reconnecting(lastKnown: liveProjection)

        await fakes.clock.setGated(true)
        var reconnectAttempt = 0
        let task = Task {
            await model.performReconnectBackoff(attempt, reconnectAttempt: &reconnectAttempt)
        }
        await fakes.clock.waitUntilSleepPending(1)
        await fakes.clock.resumeOldestSleep(throwing: CancellationError())
        let shouldContinue = await task.value
        #expect(!shouldContinue)
        // Untouched -- a cancelled sleep must never publish `.offline`.
        #expect(model.liveGameState(for: gameID) == .reconnecting(lastKnown: liveProjection))
    }

    // MARK: - Socket connect failure classification

    @Test("A transport connect failure publishes reconnecting and is retried with backoff")
    func transportConnectFailureIsRetried() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = installCurrentAttempt(for: gameID, on: model)
        let liveProjection = try BoardProjectionBuilder.makeProjection(from: loadGetGame().game)
        model.liveGameStates[gameID] = .live(liveProjection)

        var reconnectAttempt = 0
        let shouldContinue = await model.handleLiveGameSocketConnectFailure(
            attempt, error: .transport, reconnectAttempt: &reconnectAttempt
        )
        #expect(shouldContinue)
        #expect(reconnectAttempt == 1)
        let durations = await fakes.clock.requestedDurations
        #expect(durations.count == 1)
    }

    @Test("A 401 connect failure routes through session expiry and never retries")
    func connectFailure401RoutesThroughSessionExpiry() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = installCurrentAttempt(for: gameID, on: model)

        var reconnectAttempt = 0
        let shouldContinue = await model.handleLiveGameSocketConnectFailure(
            attempt, error: .http(status: 401), reconnectAttempt: &reconnectAttempt
        )
        #expect(!shouldContinue)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(model.liveGameState(for: gameID) == .idle)
        let remainingToken = try await fakes.tokenStore.token(for: ServerProfile.hosted.id)
        #expect(remainingToken == nil)
    }

    @Test("A non-401 unexpected connect status publishes a non-retryable terminal failure")
    func connectFailureUnexpectedStatusIsTerminal() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = installCurrentAttempt(for: gameID, on: model)
        let liveProjection = try BoardProjectionBuilder.makeProjection(from: loadGetGame().game)
        model.liveGameStates[gameID] = .live(liveProjection)

        var reconnectAttempt = 0
        let shouldContinue = await model.handleLiveGameSocketConnectFailure(
            attempt, error: .http(status: 500), reconnectAttempt: &reconnectAttempt
        )
        #expect(!shouldContinue)
        #expect(
            model.liveGameState(for: gameID)
                == .terminalFailure(.unexpectedStatus(500), lastKnown: liveProjection)
        )
        let durations = await fakes.clock.requestedDurations
        #expect(durations.isEmpty)
    }

    // MARK: - Subscription ownership / reference counting

    @Test("Two viewers share one session; the first unsubscribe does not tear it down")
    func twoViewersShareOneSessionUntilBothUnsubscribe() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let envelope = try loadGetGame()
        await fakes.service.enqueueGetGameResult(.success(envelope))
        await fakes.socketFactory.setGated(true)

        let firstToken = model.subscribeToLiveGame(gameID)
        // Awaiting the socket factory's connect-pending gate is the deterministic
        // proof that the REST fetch already completed and published `.live` --
        // see `subscribingMovesFromLoadingToLive`'s identical technique.
        await fakes.socketFactory.waitUntilConnectPending(1)
        #expect(
            model.liveGameState(for: gameID)
                == .live(BoardProjectionBuilder.makeProjection(from: envelope.game))
        )
        let sessionAfterFirstSubscribe = model.liveGameSessions[gameID]

        let secondToken = model.subscribeToLiveGame(gameID)
        // A second subscription to the *same* game reuses the existing session --
        // no second REST fetch/connect attempt was ever started.
        #expect(model.liveGameSessions[gameID]?.attemptID == sessionAfterFirstSubscribe?.attemptID)
        let getGameCallCount = await fakes.service.callOrder.count
        #expect(getGameCallCount == 1)

        model.unsubscribeFromLiveGame(firstToken)
        // Still alive: the second viewer is still subscribed.
        #expect(model.liveGameSessions[gameID] != nil)
        #expect(
            model.liveGameState(for: gameID)
                == .live(BoardProjectionBuilder.makeProjection(from: envelope.game))
        )

        model.unsubscribeFromLiveGame(secondToken)
        // Only the last viewer unsubscribing actually tears the session down.
        #expect(model.liveGameSessions[gameID] == nil)
        #expect(model.liveGameState(for: gameID) == .idle)
    }

    @Test("Unsubscribing an already-withdrawn token is a harmless no-op")
    func unsubscribingAlreadyWithdrawnTokenIsANoOp() {
        let (model, _) = makeSignedInModel()
        let gameID = GameID(UUID())
        let token = model.subscribeToLiveGame(gameID)
        model.unsubscribeFromLiveGame(token)
        // Calling it again must not crash or corrupt any other game's state.
        model.unsubscribeFromLiveGame(token)
        #expect(model.liveGameState(for: gameID) == .idle)
    }

    @Test("subscribeToLiveGame while signed out immediately publishes authenticationExpired")
    func subscribingWhileSignedOutPublishesAuthenticationExpired() {
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: ScriptedGameLifecycleService()
        )
        let gameID = GameID(UUID())
        _ = model.subscribeToLiveGame(gameID)
        #expect(model.liveGameState(for: gameID) == .authenticationExpired)
        #expect(model.liveGameSessions[gameID] == nil)
        #expect(!model.liveGameState(for: gameID).isRetryable)
    }

    // MARK: - retryLiveGame

    @Test("retryLiveGame is a no-op unless the current state is retryable")
    func retryIsANoOpUnlessRetryable() async {
        let (model, _) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let token = model.subscribeToLiveGame(gameID)
        // Freshly subscribed: `.loading` is not retryable.
        #expect(!model.liveGameState(for: gameID).isRetryable)
        let sessionBeforeRetry = model.liveGameSessions[gameID]?.attemptID
        model.retryLiveGame(gameID)
        // No-op: still exactly the same session, never restarted.
        #expect(model.liveGameSessions[gameID]?.attemptID == sessionBeforeRetry)
        model.unsubscribeFromLiveGame(token)
    }

    @Test("retryLiveGame restarts an offline session back to loading")
    func retryRestartsOfflineSessionToLoading() async {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let token = model.subscribeToLiveGame(gameID)
        model.liveGameStates[gameID] = .offline(lastKnown: nil)

        await fakes.service.setGetGameGated(true)
        model.retryLiveGame(gameID)
        #expect(model.liveGameState(for: gameID) == .loading)
        await fakes.service.waitUntilGetGamePending(1)
        model.unsubscribeFromLiveGame(token)
    }

    @Test("retryLiveGame does nothing when no viewer currently holds a subscription")
    func retryDoesNothingWithoutAnActiveViewer() {
        let (model, _) = makeSignedInModel()
        let gameID = GameID(UUID())
        model.liveGameStates[gameID] = .offline(lastKnown: nil)
        model.retryLiveGame(gameID)
        // No session was ever started, since nothing is subscribed.
        #expect(model.liveGameSessions[gameID] == nil)
    }

    // MARK: - Sign-out / profile-switch cancel every session

    @Test("Signing out cancels every live-game session and clears all published state")
    func signOutCancelsEveryLiveGameSession() async {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let firstGame = GameID(UUID())
        let secondGame = GameID(UUID())
        await fakes.socketFactory.setGated(true)
        await fakes.service.setGetGameGated(true)
        let firstToken = model.subscribeToLiveGame(firstGame)
        let secondToken = model.subscribeToLiveGame(secondGame)
        #expect(model.liveGameSessions.count == 2)

        model.signOut()
        await model.operationTask?.value

        #expect(model.liveGameSessions.isEmpty)
        #expect(model.liveGameViewers.isEmpty)
        #expect(model.liveGameState(for: firstGame) == .idle)
        #expect(model.liveGameState(for: secondGame) == .idle)
        model.unsubscribeFromLiveGame(firstToken)
        model.unsubscribeFromLiveGame(secondToken)
    }
}
