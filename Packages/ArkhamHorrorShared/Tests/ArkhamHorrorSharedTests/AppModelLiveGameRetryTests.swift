@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Continuation of `AppModelLiveGameTests.swift`, split purely to respect this
/// package's file/type-length lint limits: `retryLiveGame` semantics (including
/// state preservation into `.reconnecting` rather than a blank `.loading`) and
/// sign-out cancellation. Shares the same fixtures/fakes/helpers declared in the
/// primary file via this `extension`.
extension AppModelLiveGameTests {
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
        await fakes.socketFactory.setGated(true)
        let token = model.subscribeToLiveGame(gameID)
        // The initial subscribe's own socket connect is deliberately left
        // permanently pending (never resumed): this test only cares about the
        // state `retryLiveGame` restarts *from* (manually overridden below) and
        // about the fresh attempt `retryLiveGame` itself installs next, not this
        // initial attempt's own (about-to-be-superseded) progress.
        await fakes.socketFactory.waitUntilConnectPending(1)
        model.liveGameStates[gameID] = .offline(lastKnown: nil)

        model.retryLiveGame(gameID)
        #expect(model.liveGameState(for: gameID) == .loading)
        // The retry installs a fresh attempt with its own socket connect now also
        // pending (in addition to the still-abandoned initial one above it) --
        // deterministic proof this restart is actually making progress again.
        await fakes.socketFactory.waitUntilConnectPending(2)
        model.unsubscribeFromLiveGame(token)
    }

    @Test("""
    retryLiveGame restarts from a state with a known projection into reconnecting \
    (never a blank loading), preserving the board on screen through the restart
    """)
    func retryFromKnownProjectionShowsReconnectingNotBlankLoading() async throws {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        await fakes.socketFactory.setGated(true)
        let token = model.subscribeToLiveGame(gameID)
        await fakes.socketFactory.waitUntilConnectPending(1)
        let knownProjection = try BoardProjectionBuilder.makeProjection(from: loadGetGame().game)
        model.liveGameStates[gameID] = .offline(lastKnown: knownProjection)

        model.retryLiveGame(gameID)
        #expect(model.liveGameState(for: gameID) == .reconnecting(lastKnown: knownProjection))
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

    @Test("""
    retryLiveGame is a no-op for incompatiblePayload even with an active viewer, since \
    reconnecting/refetching cannot fix a genuine contract mismatch
    """)
    func retryIsANoOpForIncompatiblePayloadEvenWithAnActiveViewer() async {
        let (model, fakes) = makeSignedInModel()
        await model.flowTask?.value
        let gameID = GameID(UUID())
        await fakes.socketFactory.setGated(true)
        let token = model.subscribeToLiveGame(gameID)
        await fakes.socketFactory.waitUntilConnectPending(1)
        model.liveGameStates[gameID] = .incompatiblePayload(lastKnown: nil)
        #expect(!model.liveGameState(for: gameID).isRetryable)

        let sessionBeforeRetry = model.liveGameSessions[gameID]?.attemptID
        model.retryLiveGame(gameID)
        // No-op: a viewer is present, but the state itself is not retryable, so no
        // fresh attempt is installed.
        #expect(model.liveGameSessions[gameID]?.attemptID == sessionBeforeRetry)
        #expect(model.liveGameState(for: gameID) == .incompatiblePayload(lastKnown: nil))
        model.unsubscribeFromLiveGame(token)
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
