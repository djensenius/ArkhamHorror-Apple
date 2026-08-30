#if canImport(SwiftUI)
    @testable import ArkhamHorrorShared
    import Foundation
    import SwiftUI
    import Testing

    /// A test-only mirror of ``LiveGameView``'s own `syncSubscription()` logic
    /// (visibility/scene-phase state -> ``LiveGameSubscriptionPolicy`` ->
    /// subscribe/unsubscribe), so a scene's exact appear/disappear/scene-phase
    /// subscription lifecycle can be driven and asserted against a real
    /// ``AppModel`` without any SwiftUI view hosting. Intentionally duplicates
    /// `LiveGameView.swift`'s own private `syncSubscription()` case-switch verbatim
    /// -- this is the object under test's *specification*, not itself production
    /// code, so it must not silently drift from what `LiveGameView` actually does.
    @MainActor
    private final class TestLiveGameSubscriptionSync {
        private let model: AppModel
        private let gameID: GameID
        private(set) var subscriptionToken: LiveGameSubscriptionToken?
        private var isViewVisible = false
        private var scenePhase: ScenePhase = .active

        init(model: AppModel, gameID: GameID) {
            self.model = model
            self.gameID = gameID
        }

        var isSubscribed: Bool {
            subscriptionToken != nil
        }

        func appear() {
            isViewVisible = true
            sync()
        }

        func disappear() {
            isViewVisible = false
            sync()
        }

        func setScenePhase(_ phase: ScenePhase) {
            scenePhase = phase
            sync()
        }

        private func sync() {
            let shouldBeSubscribed = LiveGameSubscriptionPolicy.shouldBeSubscribed(
                isViewVisible: isViewVisible, scenePhase: scenePhase
            )
            switch (shouldBeSubscribed, subscriptionToken) {
            case (true, .none):
                subscriptionToken = model.subscribeToLiveGame(gameID)
            case let (false, .some(token)):
                model.unsubscribeFromLiveGame(token)
                subscriptionToken = nil
            case (true, .some), (false, .none):
                break
            }
        }
    }

    /// Continuation of `AppModelLiveGameTests.swift`, split purely to respect this
    /// package's file/type-length lint limits: multi-scene subscription-ownership
    /// coverage for two independent ``LiveGameView``-shaped scenes sharing one
    /// game's session (`LiveGameSubscriptionPolicy.swift`'s `.inactive`-stays-
    /// subscribed fix, and reference-counted teardown across scenes). Shares the
    /// same fixtures/fakes/helpers declared in the primary file via this
    /// `extension`.
    extension AppModelLiveGameTests {
        // MARK: - Multi-scene subscription ownership

        @Test("""
        Two scenes viewing the same game: one going active<->inactive many times \
        (focus handoff) never tears the shared session down and never triggers a \
        second REST fetch/socket connect
        """)
        func twoScenesActiveInactiveHandoffNoRefetchThrash() async throws {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            let gameID = GameID(UUID())
            let envelope = try loadGetGame()
            await fakes.service.setGetGameGated(true)
            await fakes.socketFactory.setGated(true)

            let sceneA = TestLiveGameSubscriptionSync(model: model, gameID: gameID)
            let sceneB = TestLiveGameSubscriptionSync(model: model, gameID: gameID)
            sceneA.appear()
            sceneB.appear()

            await fakes.socketFactory.waitUntilConnectPending(1)
            let connection = FakeGameSocketConnection()
            await fakes.socketFactory.resumeOldestConnect(with: .success(connection))
            await fakes.service.waitUntilGetGamePending(1)
            await fakes.service.resumeOldestGetGame(with: .success(envelope))
            await connection.waitUntilAwaitingNextEvent()
            #expect(
                model.liveGameState(for: gameID)
                    == .live(BoardProjectionBuilder.makeProjection(from: envelope.game))
            )

            // Many rapid active<->inactive handoffs on scene A alone, with scene B
            // never changing: per the fix, `.inactive` remains subscribed, so none
            // of these ever withdraws scene A's own subscription at all -- but even
            // if some hypothetical future change made `.inactive` withdraw it,
            // scene B's own subscription would still keep the shared session alive
            // regardless.
            for _ in 0 ..< 5 {
                sceneA.setScenePhase(.inactive)
                sceneA.setScenePhase(.active)
            }

            #expect(model.liveGameSessions[gameID] != nil)
            #expect(
                model.liveGameState(for: gameID)
                    == .live(BoardProjectionBuilder.makeProjection(from: envelope.game))
            )
            let getGameCallCount = await fakes.service.callOrder.count
            #expect(getGameCallCount == 1)
            let connectCallCount = await fakes.socketFactory.connectCallCount
            #expect(connectCallCount == 1)
        }

        @Test("""
        A sibling scene keeps a shared session alive when the other scene \
        disappears; only the very last scene disappearing tears it down, \
        preserving the last known board rather than a blank idle
        """)
        func siblingSceneSurvivesOneDisappearingLastDisappearPreservesProjection() async throws {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            let gameID = GameID(UUID())
            let envelope = try loadGetGame()
            let expectedProjection = BoardProjectionBuilder.makeProjection(from: envelope.game)
            await fakes.service.setGetGameGated(true)
            await fakes.socketFactory.setGated(true)

            let sceneA = TestLiveGameSubscriptionSync(model: model, gameID: gameID)
            let sceneB = TestLiveGameSubscriptionSync(model: model, gameID: gameID)
            sceneA.appear()
            sceneB.appear()

            await fakes.socketFactory.waitUntilConnectPending(1)
            let connection = FakeGameSocketConnection()
            await fakes.socketFactory.resumeOldestConnect(with: .success(connection))
            await fakes.service.waitUntilGetGamePending(1)
            await fakes.service.resumeOldestGetGame(with: .success(envelope))
            await connection.waitUntilAwaitingNextEvent()

            sceneA.disappear()
            // Still alive: scene B is still visible.
            #expect(model.liveGameSessions[gameID] != nil)
            #expect(model.liveGameState(for: gameID) == .live(expectedProjection))

            sceneB.disappear()
            // Only the very last scene disappearing tears the session down --
            // preserving the last known board (see `stopLiveGameSession`) rather
            // than wiping it to a blank `.idle`.
            #expect(model.liveGameSessions[gameID] == nil)
            #expect(
                model.liveGameState(for: gameID) == .reconnecting(lastKnown: expectedProjection)
            )
        }

        @Test("""
        Duplicate appear/disappear calls on the same scene are idempotent: no \
        extra subscription/viewer is created or torn down twice
        """)
        func duplicateAppearAndDisappearAreIdempotent() async {
            let (model, fakes) = makeSignedInModel()
            await model.flowTask?.value
            let gameID = GameID(UUID())
            await fakes.socketFactory.setGated(true)

            let scene = TestLiveGameSubscriptionSync(model: model, gameID: gameID)
            scene.appear()
            let tokenAfterFirstAppear = scene.subscriptionToken
            // A duplicate `appear()` (SwiftUI can legitimately deliver `onAppear`
            // more than once without an intervening `onDisappear`) must not issue a
            // second subscription/token.
            scene.appear()
            #expect(scene.subscriptionToken == tokenAfterFirstAppear)
            #expect(model.liveGameViewers[gameID]?.count == 1)

            scene.disappear()
            #expect(model.liveGameSessions[gameID] == nil)
            // A duplicate `disappear()` is a harmless no-op: nothing left to
            // withdraw.
            scene.disappear()
            #expect(model.liveGameSessions[gameID] == nil)
            #expect(model.liveGameViewers[gameID] == nil)
        }
    }
#endif
