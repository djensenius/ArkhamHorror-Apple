@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic coverage for every way an authenticated games-list refresh can be
/// interrupted without a genuine backend failure -- transport-level cancellation and
/// a stale credential-epoch token read -- split out of
/// `AppModelGameLifecycleTests.swift` purely by file length. Both must revert
/// `gameListState` out of `.loading` rather than sticking there forever, and neither
/// may ever clear a *newer*, still-pending refresh's own state.
@MainActor
@Suite("AppModel — game lifecycle refresh interruption")
struct AppModelRefreshInterruptionTests {
    private func sampleGame(id: UUID = UUID(), name: String = "Sample") -> GameSummary {
        GameSummary(
            id: GameID(id),
            scenario: nil,
            campaign: nil,
            gameState: .active,
            name: name,
            investigators: [],
            otherInvestigators: [],
            multiplayerVariant: .solo,
            hasOpenSeats: false
        )
    }

    // MARK: - Cancellation

    @Test(
        "A still-current refresh's cancellation reverts .loading to .idle rather than sticking"
    )
    func cancellationOfCurrentRefreshRevertsToIdle() async {
        let service = ScriptedGameLifecycleService()
        await service.setListGamesGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.refreshGames()
        await service.waitUntilListGamesPending(1)
        #expect(model.gameListState == .loading(previous: nil))

        await service.resumeOldestListGames(with: .failure(CancellationError()))
        await model.gameListTask?.value

        #expect(model.gameListState == .idle)
    }

    @Test(
        """
        A still-current refresh's cancellation reverts .loading back to the prior \
        loaded content, never dropping it
        """
    )
    func cancellationOfCurrentRefreshRevertsToPriorContent() async {
        let service = ScriptedGameLifecycleService()
        let games: GameList = [.game(sampleGame())]
        await service.enqueueListGamesResult(.success(games))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.refreshGames()
        await model.gameListTask?.value
        #expect(model.gameListState == .loaded(games))

        await service.setListGamesGated(true)
        model.refreshGames()
        await service.waitUntilListGamesPending(1)
        await service.resumeOldestListGames(with: .failure(CancellationError()))
        await model.gameListTask?.value

        #expect(model.gameListState == .loaded(games))
    }

    @Test(
        "A superseded refresh's cancellation never clears a newer, still-pending refresh's state"
    )
    func cancellationOfSupersededRefreshDoesNotClearNewerPendingState() async {
        let service = ScriptedGameLifecycleService()
        await service.setListGamesGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.refreshGames()
        await service.waitUntilListGamesPending(1)
        let staleRefreshTask = model.gameListTask
        model.refreshGames()
        await service.waitUntilListGamesPending(2)

        // The older (now-stale) refresh observes cancellation while the newer one is
        // still genuinely pending. Awaiting its captured task directly (rather than
        // guessing with `Task.yield()`) guarantees its full completion -- including
        // this exact `revertGameListStateAfterCancellation` guard -- has actually run
        // before the assertion below, so a regression here is never masked by
        // insufficient synchronization.
        await service.resumeOldestListGames(with: .failure(CancellationError()))
        await staleRefreshTask?.value

        #expect(model.gameListState == .loading(previous: nil))
    }

    // MARK: - Stale credential-epoch token reads (distinct from cancellation/401)

    // See the matching comment in `AppModelGameLifecycleSessionExpiryTests.swift`:
    // `currentGameLifecycleToken(for:)` always reads the credential epoch fresh, so
    // `.stale` can only surface when a read is queued behind another still-in-flight
    // token-store operation for the same profile and a *second* concurrent
    // invalidation lands while it is still waiting there. Reproduced here with a
    // real `enqueueCancellationCleanup` reservation (the same primitive an endpoint
    // edit/removal uses) gated via `GatedTokenStore`.

    @Test(
        """
        A stale credential-epoch token read for a still-current refresh reverts \
        .loading without recording a failure or resetting the session
        """
    )
    func staleTokenReadForCurrentRefreshRevertsToIdleWithoutFailure() async {
        let tokenStore = GatedTokenStore(tokens: [ServerProfile.hosted.id: "token"])
        let service = ScriptedGameLifecycleService()
        let admissions = TokenAccessAdmissionCounter()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: service
        )
        await model.flowTask?.value
        model.tokenAccessAdmissionHook = admissions.hook

        // A concurrent cleanup reservation for the same profile -- mirrors an
        // endpoint edit/removal's `reserveCleanupInterruptingActiveAuth` -- whose own
        // token deletion is gated so it does not complete yet.
        guard case let .reserved(cleanupTask) = model.enqueueCancellationCleanup(
            for: ServerProfile.hosted.id, globalEpoch: model.currentGlobalCredentialEpoch()
        ) else {
            Issue.record("Expected the cleanup reservation to succeed.")
            return
        }

        model.refreshGames()
        // Waits for the refresh's own token read to have captured its still-current
        // epoch and queued itself behind the reservation above.
        await admissions.waitForAdmissions(2, of: ServerProfile.hosted.id)

        // A second concurrent invalidation while the refresh's read is still
        // genuinely queued behind the first reservation's gated deletion.
        model.invalidateCredentialEpoch(for: ServerProfile.hosted.id)

        // Let the reservation's gated deletion resolve (failing, as if a concurrent
        // Keychain/profile-store failure had interrupted it, leaving the token
        // itself intact -- only the epoch invalidation matters here), unblocking
        // the refresh's own queued check, which must now observe the mismatch.
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest(throwing: TestFailure())
        await model.gameListTask?.value
        _ = await cleanupTask.value

        #expect(model.gameListState == .idle)
        guard case .signedIn = model.sessionState else {
            Issue.record("Expected sessionState to remain signedIn, was \(model.sessionState)")
            return
        }
    }

    @Test(
        "A superseded refresh's stale credential-epoch read never clears a newer refresh's state"
    )
    func staleTokenReadForSupersededRefreshDoesNotClearNewerPendingState() async {
        let tokenStore = GatedTokenStore(tokens: [ServerProfile.hosted.id: "token"])
        let service = ScriptedGameLifecycleService()
        await service.setListGamesGated(true)
        let admissions = TokenAccessAdmissionCounter()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: service
        )
        await model.flowTask?.value
        model.tokenAccessAdmissionHook = admissions.hook

        guard case let .reserved(cleanupTask) = model.enqueueCancellationCleanup(
            for: ServerProfile.hosted.id, globalEpoch: model.currentGlobalCredentialEpoch()
        ) else {
            Issue.record("Expected the cleanup reservation to succeed.")
            return
        }

        // R1: begins refreshing, capturing the still-current epoch (0) and queuing
        // its token read behind the reservation above.
        model.refreshGames()
        let staleRefreshTask = model.gameListTask
        await admissions.waitForAdmissions(2, of: ServerProfile.hosted.id)

        // Invalidated while R1's read is still queued -- R1's captured epoch (0) is
        // now genuinely stale.
        model.invalidateCredentialEpoch(for: ServerProfile.hosted.id)

        // R2: a newer refresh supersedes R1 and captures the new, current epoch (1)
        // as its own -- R2 is not itself stale; its token read simply queues behind
        // R1's (still pending on the reservation) and, once reached, will match
        // cleanly.
        model.refreshGames()

        // Unblock the reservation (failing, leaving the token intact for R2's read).
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest(throwing: TestFailure())
        await staleRefreshTask?.value

        // R2's own (unaffected) token read now resolves and its service call is
        // reached and held at the existing service-level gate.
        await service.waitUntilListGamesPending(1)

        // R2 is still genuinely in flight; R1's stale token read must not have
        // reverted R2's own .loading state.
        #expect(model.gameListState == .loading(previous: nil))

        await service.resumeOldestListGames(with: .success([]))
        await model.gameListTask?.value
        _ = await cleanupTask.value
    }
}
