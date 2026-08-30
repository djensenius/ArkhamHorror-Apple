@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Continuation of `AppModelLiveGameTests.swift`, split purely to respect this
/// package's file/type-length lint limits: `runLiveGameSession`'s
/// stable-connection-gated `reconnectAttempt` reset (`AppModel+LiveGameSession.swift`,
/// `LiveGameReconnectPolicy.stableConnectionDuration`) -- proving a flapping
/// (accept-then-immediate-close) connection can never reset its own backoff budget
/// and therefore always reaches `.offline` in bounded attempts, while a connection
/// that genuinely stays open long enough *does* reset the budget for whatever comes
/// next. Shares the same fixtures/fakes/helpers declared in the primary file via
/// this `extension`.
extension AppModelLiveGameTests {
    // MARK: - Reconnect attempt-budget stability (flapping connections)

    @Test("""
    A connection that accepts then immediately closes on every attempt never resets \
    its reconnect budget, exhausting it to offline in bounded attempts rather than \
    looping forever
    """)
    func flappingConnectionNeverResetsBudgetAndReachesOffline() async throws {
        let (model, fakes) = makeSignedInModel(randomValues: [0.5])
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let envelope = try loadGetGame()
        let expectedProjection = BoardProjectionBuilder.makeProjection(from: envelope.game)
        await fakes.service.setGetGameGated(true)
        await fakes.socketFactory.setGated(true)

        let token = model.subscribeToLiveGame(gameID)
        let task = try #require(model.liveGameSessions[gameID]?.task)

        // `maximumAttempts + 1` flaps: each connects, refetches REST, then is
        // immediately closed before the fake clock ever advances -- so none of
        // them ever qualifies as "stable" (see `stableConnectionDuration`), and the
        // reconnect budget accumulates across every single one rather than
        // resetting after each "successful" handshake. The very last one is the
        // one that finally exhausts the budget and stops the loop for good.
        for _ in 0 ..< (LiveGameReconnectPolicy.maximumAttempts + 1) {
            await fakes.socketFactory.waitUntilConnectPending(1)
            let connection = FakeGameSocketConnection()
            await connection.enqueue(.event(.closed(code: .normalClosure, reason: nil)))
            await fakes.socketFactory.resumeOldestConnect(with: .success(connection))
            await fakes.service.waitUntilGetGamePending(1)
            await fakes.service.resumeOldestGetGame(with: .success(envelope))
        }

        // No further gate is needed to observe the terminal transition: once the
        // budget-exhausting call to `performReconnectBackoff` returns `false`,
        // `runLiveGameSession` returns and this task itself completes.
        await task.value
        #expect(model.liveGameState(for: gameID) == .offline(lastKnown: expectedProjection))

        // Never more than `maximumAttempts + 1` connects/fetches -- proving this
        // can never become an unbounded retry storm/hot loop, even though every
        // single attempt technically "succeeded" its own handshake.
        let connectCallCount = await fakes.socketFactory.connectCallCount
        #expect(connectCallCount == LiveGameReconnectPolicy.maximumAttempts + 1)
        let getGameCallCount = await fakes.service.callOrder.count
        #expect(getGameCallCount == LiveGameReconnectPolicy.maximumAttempts + 1)

        // Every one of the `maximumAttempts` sleeps requested a strictly
        // increasing delay ceiling, following the normal 0...maximumAttempts-1
        // schedule with no resets in between: the old, buggy unconditional-reset
        // behavior would instead request `jitteredDelay(forAttempt: 0, ...)` after
        // every single flap forever, never reaching `maximumAttempts` and never
        // publishing `.offline` at all.
        let durations = await fakes.clock.requestedDurations
        #expect(durations.count == LiveGameReconnectPolicy.maximumAttempts)
        for (index, duration) in durations.enumerated() {
            let expected = LiveGameReconnectPolicy.jitteredDelay(
                forAttempt: index, unitInterval: 0.5
            )
            #expect(duration == expected)
        }
        model.unsubscribeFromLiveGame(token)
    }

    @Test("""
    A connection that stays open at least the stable-connection duration before \
    being lost resets the reconnect budget, so the very next flap after it requests \
    attempt 0's delay again rather than continuing to climb
    """)
    func stableConnectionResetsReconnectBudget() async throws {
        let (model, fakes) = makeSignedInModel(randomValues: [0.5])
        await model.flowTask?.value
        let gameID = GameID(UUID())
        let envelope = try loadGetGame()
        await fakes.service.setGetGameGated(true)
        await fakes.socketFactory.setGated(true)

        let token = model.subscribeToLiveGame(gameID)

        // First: a few unstable flaps (never reaching the stable duration), so the
        // reconnect budget partway accumulates -- mirroring
        // `flappingConnectionNeverResetsBudgetAndReachesOffline`'s own setup.
        let unstableFlapCount = 3
        for _ in 0 ..< unstableFlapCount {
            await fakes.socketFactory.waitUntilConnectPending(1)
            let connection = FakeGameSocketConnection()
            await connection.enqueue(.event(.closed(code: .normalClosure, reason: nil)))
            await fakes.socketFactory.resumeOldestConnect(with: .success(connection))
            await fakes.service.waitUntilGetGamePending(1)
            await fakes.service.resumeOldestGetGame(with: .success(envelope))
        }
        // The *next* `connect(to:)` call becoming pending is itself deterministic
        // proof that the last flap's own `performReconnectBackoff` sleep already
        // completed and recorded its duration (that sleep is a required
        // predecessor of this next connect attempt): checking
        // `requestedDurations` only once this gate resolves avoids racing the
        // model's own task, which needs further suspension hops past
        // `resumeOldestGetGame` to actually reach and record that sleep.
        await fakes.socketFactory.waitUntilConnectPending(1)
        let durationsAfterUnstableFlaps = await fakes.clock.requestedDurations.count
        #expect(durationsAfterUnstableFlaps == unstableFlapCount)

        // Now: a connection that stays open long enough to count as stable before
        // being lost -- the fake clock is advanced *after* this connection's own
        // REST refetch publishes (matching exactly where `connectedAt` is
        // captured in `runLiveGameSession`) and *before* its loss, simulating real
        // elapsed uptime without any real waiting.
        let stableConnection = FakeGameSocketConnection()
        await fakes.socketFactory.resumeOldestConnect(with: .success(stableConnection))
        await fakes.service.waitUntilGetGamePending(1)
        await fakes.service.resumeOldestGetGame(with: .success(envelope))
        await stableConnection.waitUntilAwaitingNextEvent()
        await fakes.clock.advance(by: LiveGameReconnectPolicy.stableConnectionDuration)
        await stableConnection.enqueue(.event(.closed(code: .normalClosure, reason: nil)))

        // The budget having reset, the very *next* flap's requested delay is
        // attempt `0`'s again -- proving the reset actually happened, rather than
        // merely that the counter continued climbing from `unstableFlapCount`.
        await fakes.socketFactory.waitUntilConnectPending(1)
        let durationsAfterStableConnection = await fakes.clock.requestedDurations
        #expect(durationsAfterStableConnection.count == unstableFlapCount + 1)
        let resetDelay = durationsAfterStableConnection.last
        let expectedResetDelay = LiveGameReconnectPolicy.jitteredDelay(
            forAttempt: 0, unitInterval: 0.5
        )
        #expect(resetDelay == expectedResetDelay)
        model.unsubscribeFromLiveGame(token)
    }
}
