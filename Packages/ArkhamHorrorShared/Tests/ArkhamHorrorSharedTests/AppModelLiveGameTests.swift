@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic coverage for the live-game session runner (`AppModel+LiveGame.swift`/
/// `AppModel+LiveGameSession.swift`/`AppModel+LiveGameSocket.swift`): subscription
/// ownership, REST/socket connect ordering, reconnect-with-backoff, failure
/// classification, cancellation at every handoff point, and stale-generation safety.
///
/// Two complementary styles are used throughout, matching this package's existing
/// convention (see e.g. `AppModel+GameLifecycleActions.swift`'s own test suite):
/// full end-to-end coverage drives ``AppModel/subscribeToLiveGame(_:)``/
/// ``AppModel/unsubscribeFromLiveGame(_:)`` and awaits the real session task: gates
/// on the injected fakes below make every suspension point deterministic without
/// ever relying on `Task.yield()` timing. Narrower unit coverage calls the session
/// runner's own internal steps (``AppModel/consumeLiveGameSocket(_:connection:projection:)``,
/// ``AppModel/connectLiveGameSocket(_:)``,
/// ``AppModel/handleLiveGameSocketConnectFailure(_:error:reconnectAttempt:)``,
/// ``AppModel/performReconnectBackoff(_:reconnectAttempt:)``) directly against a
/// hand-crafted ``LiveGameSessionAttempt``, exercising the exact same production code
/// with no task-scheduling nondeterminism at all -- the most direct way to prove a
/// stale/cancelled attempt's step can never publish state or mutate a newer
/// generation's session.
@MainActor
@Suite("AppModel — live game")
struct AppModelLiveGameTests {
    // MARK: - Fixtures

    func fixtureData(named fileName: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: fileName,
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        return try Data(contentsOf: url)
    }

    func loadGetGame() throws -> GetGameEnvelope {
        try ContractJSON.decode(GetGameEnvelope.self, from: fixtureData(named: "get-game"))
    }

    func loadGameUpdateData() throws -> Data {
        try fixtureData(named: "game-update")
    }

    // MARK: - Model construction

    struct Fakes {
        let tokenStore: FakeTokenStore
        let service: ScriptedGameLifecycleService
        let socketFactory: FakeGameSocketFactory
        let clock: FakeLiveGameClock
        let random: FakeLiveGameRandomSource
    }

    func makeSignedInModel(
        initialToken: String = "t1-token",
        reauthenticateWithToken: String = "t2-token",
        randomValues: [Double] = [0]
    ) -> (model: AppModel, fakes: Fakes) {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: initialToken])
        let service = ScriptedGameLifecycleService()
        let socketFactory = FakeGameSocketFactory()
        let clock = FakeLiveGameClock()
        let random = FakeLiveGameRandomSource(values: randomValues)
        let auth = ScriptedAuthenticating(
            authenticateResult: .success(AuthToken(token: reauthenticateWithToken)),
            currentUserResult: .success(.sample)
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: service,
            liveGameSocketFactory: socketFactory,
            liveGameClock: clock,
            liveGameRandomSource: random
        )
        return (
            model,
            Fakes(
                tokenStore: tokenStore, service: service, socketFactory: socketFactory,
                clock: clock, random: random
            )
        )
    }

    /// Builds a ``LiveGameSessionAttempt`` and installs it as `gameID`'s current
    /// session in `model.liveGameSessions`, so ``AppModel/isCurrentLiveGameSession(_:)``
    /// reports it current for direct unit-level calls into the session runner's own
    /// steps, without ever going through the real async task/subscribe machinery.
    func installCurrentAttempt(
        for gameID: GameID, on model: AppModel, profile: ServerProfile = .hosted
    ) -> LiveGameSessionAttempt {
        let attempt = LiveGameSessionAttempt(
            gameID: gameID,
            profile: profile,
            attemptID: UUID(),
            sessionGeneration: model.generation,
            credentialEpoch: model.currentCredentialEpoch(for: profile.id),
            globalEpoch: model.currentGlobalCredentialEpoch()
        )
        model.liveGameSessions[gameID] = LiveGameSessionHandle(
            attemptID: attempt.attemptID, task: Task {}
        )
        return attempt
    }

    // MARK: - Initial subscribe: REST-first ordering, idle→loading→live

    @Test("Subscribing moves idle → loading, then live once the REST snapshot is published")
    func subscribingMovesFromLoadingToLive() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let envelope = try loadGetGame()
        let expectedProjection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        let gameID = GameID(UUID())
        #expect(model.liveGameState(for: gameID) == .idle)

        await fakes.service.setGetGameGated(true)
        await fakes.socketFactory.setGated(true)
        let token = model.subscribeToLiveGame(gameID)
        #expect(model.liveGameState(for: gameID) == .loading)

        await fakes.service.waitUntilGetGamePending(1)
        await fakes.service.resumeOldestGetGame(with: .success(envelope))
        // Awaiting the socket factory's own connect-pending gate is itself the
        // deterministic proof that the REST fetch's completion already ran and
        // published `.live` on this session's single serial task -- the socket
        // connect that gate observes only ever happens *after* that publish (see
        // `runLiveGameSession`'s reconnect-ordering documentation), so no polling of
        // `liveGameState` is needed to observe it.
        await fakes.socketFactory.waitUntilConnectPending(1)
        #expect(model.liveGameState(for: gameID) == .live(expectedProjection))

        // The socket connect only ever happens *after* this first REST fetch
        // publishes -- proven directly by the recorded call order.
        let callOrder = await fakes.service.callOrder
        #expect(callOrder == ["getGame"])
        model.unsubscribeFromLiveGame(token)
    }

    @Test("The first connection's REST fetch is issued strictly before the socket connect")
    func firstConnectionFetchesRESTBeforeOpeningSocket() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let envelope = try loadGetGame()
        let gameID = GameID(UUID())

        await fakes.service.setGetGameGated(true)
        await fakes.socketFactory.setGated(true)
        let token = model.subscribeToLiveGame(gameID)

        await fakes.service.waitUntilGetGamePending(1)
        // The socket factory must not have been reached at all yet.
        let connectCallCountBeforeFetch = await fakes.socketFactory.connectCallCount
        #expect(connectCallCountBeforeFetch == 0)

        await fakes.service.resumeOldestGetGame(with: .success(envelope))
        await fakes.socketFactory.waitUntilConnectPending(1)
        let connectCallCountAfterFetch = await fakes.socketFactory.connectCallCount
        #expect(connectCallCountAfterFetch == 1)
        model.unsubscribeFromLiveGame(token)
    }

    // MARK: - REST 401 / session expiry

    @Test("A REST 401 deletes the token and ends signed in, leaving the live state cleared")
    func restSessionExpiryDeletesTokenAndClearsLiveState() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        await fakes.service.enqueueGetGameResult(.failure(GameLifecycleError.sessionExpired))

        model.subscribeToLiveGame(gameID)
        // The session-expiry path is a genuine terminal exit for this session's own
        // runner task (see `fetchLiveGameProjection`'s `sessionExpired` handling),
        // so capturing and awaiting the task itself -- before `resetLiveGameState()`
        // clears `liveGameSessions` out from under this lookup -- deterministically
        // waits for every one of its own awaited steps (session-expiry routing,
        // token deletion, `resetGameLifecycleState()`) to have fully completed.
        let task = try #require(model.liveGameSessions[gameID]?.task)
        await task.value

        // `resetGameLifecycleState()` -- the same choke point every other
        // authenticated 401 flows through -- clears every live-game session/state
        // entirely, regardless of which game triggered it.
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(model.liveGameState(for: gameID) == .idle)
        #expect(model.liveGameSessions[gameID] == nil)
        let remainingToken = try await fakes.tokenStore.token(for: ServerProfile.hosted.id)
        #expect(remainingToken == nil)
    }

    @Test("A stale live-game 401 after sign-out and re-sign-in cannot delete the newer token")
    func staleLiveGame401CannotDeleteNewerToken() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        await fakes.service.setGetGameGated(true)

        model.subscribeToLiveGame(gameID)
        await fakes.service.waitUntilGetGamePending(1)
        // Captured before sign-out clears `liveGameSessions`, so this test can
        // deterministically await this stale session's full completion later.
        let staleTask = try #require(model.liveGameSessions[gameID]?.task)

        model.signOut()
        await model.operationTask?.value
        model.signIn(AuthenticationCredentials(email: "a@example.com", password: "pw"))
        await model.operationTask?.value
        #expect(
            model.sessionState == .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )
        let tokenAfterSignIn = try await fakes.tokenStore.token(for: ServerProfile.hosted.id)
        #expect(tokenAfterSignIn == "t2-token")

        // The stale, pre-sign-out `getGame` finally resolves with a 401. By this
        // point `resetLiveGameState()` (run as part of sign-out) has already
        // cleared `liveGameSessions` entirely, so `isCurrentLiveGameSession` for
        // this stale attempt is already false; awaiting the captured task
        // deterministically proves its completion (discarded at that very check,
        // never even reaching `handleGameLifecycleSessionExpired`) has fully run.
        await fakes.service.resumeOldestGetGame(with: .failure(GameLifecycleError.sessionExpired))
        await staleTask.value

        let tokenAfterStaleRace = try await fakes.tokenStore.token(for: ServerProfile.hosted.id)
        #expect(tokenAfterStaleRace == "t2-token")
        #expect(
            model.sessionState == .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )
    }

    // MARK: - Decode failure

    @Test("A malformed WebSocket frame publishes incompatiblePayload and closes the socket once")
    func malformedSocketFramePublishesIncompatiblePayload() async throws {
        let (model, _) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = installCurrentAttempt(for: gameID, on: model)
        let envelope = try loadGetGame()
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        model.liveGameStates[gameID] = .live(projection)

        let connection = FakeGameSocketConnection()
        await connection.enqueue(.event(.message(Data("not valid contract json".utf8))))

        let outcome = await model.consumeLiveGameSocket(
            attempt, connection: connection, projection: projection
        )
        #expect(outcome == .stopped)
        #expect(model.liveGameState(for: gameID) == .incompatiblePayload(lastKnown: projection))
        await connection.waitUntilClosed()
        let closeCount = await connection.closeCallCount
        #expect(closeCount == 1)
    }

    @Test("An unsupported ServerMessage tag is ignored, never treated as an incompatibility")
    func unsupportedServerMessageIsIgnored() async throws {
        let (model, _) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = installCurrentAttempt(for: gameID, on: model)
        let envelope = try loadGetGame()
        let projection = BoardProjectionBuilder.makeProjection(from: envelope.game)

        let connection = FakeGameSocketConnection()
        let unsupportedJSON = Data("""
        {"tag":"SomethingElse","contents":null}
        """.utf8)
        await connection.enqueue(.event(.message(unsupportedJSON)))
        await connection.enqueue(.event(.closed(code: .normalClosure, reason: nil)))

        let outcome = await model.consumeLiveGameSocket(
            attempt, connection: connection, projection: projection
        )
        #expect(outcome == .lost(projection))
        // Never overwritten to `.incompatiblePayload` by the ignored frame.
        #expect(model.liveGameState(for: gameID) != .incompatiblePayload(lastKnown: projection))
    }

    @Test("A valid WebSocket snapshot frame publishes live with the exact decoded projection")
    func validSocketSnapshotPublishesLive() async throws {
        let (model, _) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let attempt = installCurrentAttempt(for: gameID, on: model)
        let envelope = try loadGetGame()
        let initialProjection = BoardProjectionBuilder.makeProjection(from: envelope.game)

        let connection = FakeGameSocketConnection()
        let update = try loadGameUpdateData()
        await connection.enqueue(.event(.message(update)))
        await connection.enqueue(.event(.closed(code: .normalClosure, reason: nil)))

        _ = await model.consumeLiveGameSocket(
            attempt, connection: connection, projection: initialProjection
        )
        let decodedUpdate = try ContractJSON.decode(BoardSnapshotUpdate.self, from: update)
        guard case let .snapshot(snapshot) = decodedUpdate else {
            Issue.record("Expected the game-update fixture to decode to .snapshot")
            return
        }
        let expected = BoardProjectionBuilder.makeProjection(from: snapshot)
        #expect(model.liveGameState(for: gameID) == .live(expected))
    }
}
