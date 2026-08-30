@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic coverage for the game-lifecycle 401 (`GameLifecycleError.sessionExpired`)
/// handling race identified in review: a per-game action's (or `createGame`'s) stale
/// completion must never be able to authorize deleting a *different*, newer session's
/// token, and cancellation observed after a response was already in flight must never
/// be misreported as an actionable failure.
@MainActor
@Suite("AppModel — game lifecycle session expiry")
struct AppModelGameLifecycleSessionExpiryTests {
    private func makeSignedInModel(
        service: ScriptedGameLifecycleService,
        initialToken: String,
        reauthenticateWithToken: String
    ) -> (model: AppModel, tokenStore: FakeTokenStore) {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: initialToken])
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
            gameLifecycleService: service
        )
        return (model, tokenStore)
    }

    @Test(
        """
        A stale action's 401, arriving after sign-out and a newer sign-in to the same \
        profile, cannot delete the newer session's token or disturb its state
        """
    )
    func staleActionSessionExpiryCannotDeleteNewerToken() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.setDeleteGameGated(true)
        let (model, tokenStore) = makeSignedInModel(
            service: service, initialToken: "t1-token", reauthenticateWithToken: "t2-token"
        )
        await model.flowTask?.value
        #expect(
            model.sessionState == .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )

        // T1: a delete for `gameID` begins while signed in with the original token.
        model.deleteGame(gameID)
        await service.waitUntilDeleteGamePending(1)
        // Captured before sign-out clears `gameLifecycleActionTasks` (as part of
        // `resetGameLifecycleState()`), so this test can deterministically await T1's
        // full completion later -- including every awaited step inside its own
        // session-expiry handling -- instead of guessing with `Task.yield()`.
        let staleDeleteTask = model.gameLifecycleActionTasks[gameID]

        // Sign out, then sign back in to the *same* profile with a fresh token (T2).
        model.signOut()
        await model.operationTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        model.signIn(AuthenticationCredentials(email: "a@example.com", password: "pw"))
        await model.operationTask?.value
        #expect(
            model.sessionState == .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )
        let tokenAfterSignIn = try await tokenStore.token(for: ServerProfile.hosted.id)
        #expect(tokenAfterSignIn == "t2-token")

        // T1's now-stale delete finally resolves with a 401.
        await service.resumeOldestDeleteGame(with: .failure(GameLifecycleError.sessionExpired))
        await staleDeleteTask?.value

        // The newer session (T2) must be completely undisturbed: still signed in, and
        // its own freshly saved token must not have been deleted by T1's stale 401.
        #expect(
            model.sessionState == .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )
        let tokenAfterStaleRace = try await tokenStore.token(for: ServerProfile.hosted.id)
        #expect(tokenAfterStaleRace == "t2-token")
    }

    @Test("A still-current action's 401 does delete its token and transitions to signedOut")
    func currentActionSessionExpiryStillSignsOut() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueueDeleteGameResult(.failure(GameLifecycleError.sessionExpired))
        let (model, tokenStore) = makeSignedInModel(
            service: service, initialToken: "t1-token", reauthenticateWithToken: "t2-token"
        )
        await model.flowTask?.value

        model.deleteGame(gameID)
        await model.gameLifecycleActionTasks[gameID]?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        let tokenAfter = try await tokenStore.token(for: ServerProfile.hosted.id)
        #expect(tokenAfter == nil)
        #expect(model.gameListState == .idle)
    }

    @Test(
        """
        A missing token for a still-current action routes through session-expiry \
        and signs out, rather than leaving the app on the signed-in route with no \
        usable token
        """
    )
    func noTokenForCurrentActionSignsOut() async throws {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "token"])
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore(),
            gameLifecycleService: service
        )
        await model.flowTask?.value
        #expect(
            model.sessionState == .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )

        // Simulates a concurrent event (e.g. a sign-out or storage reset) having
        // already durably deleted the token before `sessionState` observed it.
        try await tokenStore.deleteToken(for: ServerProfile.hosted.id)

        model.deleteGame(gameID)
        await model.gameLifecycleActionTasks[gameID]?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(model.gameListState == .idle)
    }

    @Test(
        """
        Cancellation observed after the response is in flight is never recorded as a \
        failure, but does clear the in-flight marker so the row is never stuck
        """
    )
    func cancellationAfterResponseIsNotRecordedAsFailure() async {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.enqueueDeleteGameResult(.failure(CancellationError()))
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        model.deleteGame(gameID)
        await model.gameLifecycleActionTasks[gameID]?.value

        // Cancellation must be silently swallowed (no failure recorded), but since
        // this attempt is still `gameID`'s current one (nothing superseded it), the
        // in-flight marker must be cleared back to `nil` -- never left stuck at
        // `.deleting` forever with the row's controls permanently disabled and no
        // way to retry.
        #expect(model.gameLifecycleActions[gameID] == nil)
        #expect(model.gameLifecycleActionFailures[gameID] == nil)
        #expect(model.sessionState.isSignedIn)
    }

    @Test(
        "A superseded action's cancellation never clears a newer, still-pending action's own marker"
    )
    func cancellationOfSupersededActionDoesNotClearNewerPendingMarker() async {
        let service = ScriptedGameLifecycleService()
        let gameID = GameID(UUID())
        await service.setDeleteGameGated(true)
        let model = await GameLifecycleTestModel.makeSignedIn(gameService: service)

        // T1: begins deleting `gameID`.
        model.deleteGame(gameID)
        await service.waitUntilDeleteGamePending(1)
        let staleDeleteTask = model.gameLifecycleActionTasks[gameID]

        // T2: a newer delete for the *same* game supersedes T1, which is still gated
        // (pending) at this point.
        model.deleteGame(gameID)
        await service.waitUntilDeleteGamePending(2)
        #expect(model.gameLifecycleActions[gameID] == .deleting)

        // T1's now-stale call observes cancellation.
        await service.resumeOldestDeleteGame(with: .failure(CancellationError()))
        await staleDeleteTask?.value

        // T2 is still genuinely in flight; T1's stale cancellation must not have
        // cleared T2's own marker prematurely.
        #expect(model.gameLifecycleActions[gameID] == .deleting)
        #expect(model.gameLifecycleActionFailures[gameID] == nil)
    }

    // MARK: - Stale credential-epoch token reads (distinct from cancellation/401)

    //
    // `currentGameLifecycleToken(for:)` always reads the credential epoch *fresh*,
    // right before entering `serializedTokenAccess`'s queue for that profile -- it
    // never reuses the value `beginGameAction` captured earlier into `GameActionAttempt`
    // (that capture exists only for `handleGameLifecycleSessionExpired`'s own guard).
    // So `GameLifecycleTokenAccessError.stale` can only actually surface when a read
    // is queued *behind* another still-in-flight token-store operation for the same
    // profile (via `previous` in `serializedTokenAccess`), and a *second* concurrent
    // invalidation lands while it is still waiting there -- exactly the review
    // scenario: a still-signed-in profile's credential epoch changes out from under
    // an already-queued game action. Both tests below reproduce this with a real
    // `enqueueCancellationCleanup` reservation (the same primitive an endpoint
    // edit/removal uses) gated via `GatedTokenStore`, rather than a bare
    // `invalidateCredentialEpoch` call, which alone can never trigger this path.

    @Test(
        """
        A stale credential-epoch token read for a still-current action clears its \
        in-flight marker without recording a failure, deleting its token, or \
        resetting the session
        """
    )
    func staleTokenReadForCurrentActionClearsMarkerWithoutFailure() async {
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
        let gameID = GameID(UUID())

        // A concurrent cleanup reservation for the *same* profile -- exactly what an
        // endpoint edit/removal's `reserveCleanupInterruptingActiveAuth` issues --
        // whose own token deletion is gated so it does not complete yet.
        guard case let .reserved(cleanupTask) = model.enqueueCancellationCleanup(
            for: ServerProfile.hosted.id, globalEpoch: model.currentGlobalCredentialEpoch()
        ) else {
            Issue.record("Expected the cleanup reservation to succeed.")
            return
        }

        model.deleteGame(gameID)
        // Waits for the delete's own token read to have captured its still-current
        // epoch and queued itself behind the reservation above (admission #1 was the
        // reservation itself; #2 is this delete's read).
        await admissions.waitForAdmissions(2, of: ServerProfile.hosted.id)

        // A second concurrent invalidation while the delete's read is still
        // genuinely queued behind the first reservation's gated deletion.
        model.invalidateCredentialEpoch(for: ServerProfile.hosted.id)

        // Let the reservation's gated deletion resolve (failing, as if a concurrent
        // Keychain/profile-store failure had interrupted it -- exactly the
        // "restartFlow never runs" review scenario -- so the token itself is left
        // intact; only the epoch invalidation, which always happens synchronously at
        // reservation time regardless of whether the deletion itself later
        // succeeds, is what matters here), unblocking the delete's own queued
        // check, which must now observe the epoch mismatch.
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest(throwing: TestFailure())
        await model.gameLifecycleActionTasks[gameID]?.value
        _ = await cleanupTask.value

        #expect(model.gameLifecycleActions[gameID] == nil)
        #expect(model.gameLifecycleActionFailures[gameID] == nil)
        // The concurrent cleanup reservation (simulating some other legitimate
        // in-flight operation, e.g. an endpoint edit) is the one that actually
        // deletes the token here -- that is its own correct behavior, orthogonal to
        // this assertion. What matters for *this* delete's stale read is that it
        // never itself calls `handleGameLifecycleSessionExpired` (which would
        // redundantly touch the token store again and flip `sessionState`) --
        // confirmed by the session remaining signed in below.
        #expect(model.sessionState.isSignedIn)
    }

    @Test(
        "A superseded action's stale credential-epoch read never clears a newer action's marker"
    )
    func staleTokenReadForSupersededActionDoesNotClearNewerMarker() async {
        let tokenStore = GatedTokenStore(tokens: [ServerProfile.hosted.id: "token"])
        let service = ScriptedGameLifecycleService()
        await service.setDeleteGameGated(true)
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
        let gameID = GameID(UUID())

        // A concurrent cleanup reservation for the same profile, gated exactly as
        // above.
        guard case let .reserved(cleanupTask) = model.enqueueCancellationCleanup(
            for: ServerProfile.hosted.id, globalEpoch: model.currentGlobalCredentialEpoch()
        ) else {
            Issue.record("Expected the cleanup reservation to succeed.")
            return
        }

        // T1: begins deleting `gameID`, capturing the still-current epoch (0) and
        // queuing its token read behind the reservation above.
        model.deleteGame(gameID)
        let staleDeleteTask = model.gameLifecycleActionTasks[gameID]
        await admissions.waitForAdmissions(2, of: ServerProfile.hosted.id)

        // Invalidated while T1's read is still queued -- T1's captured epoch (0) is
        // now genuinely stale.
        model.invalidateCredentialEpoch(for: ServerProfile.hosted.id)

        // T2: a newer delete for the *same* game supersedes T1 and captures the new,
        // current epoch (1) as its own -- T2 is not itself stale; its token read
        // simply queues behind T1's (still pending on the reservation) and, once
        // reached, will match cleanly.
        model.deleteGame(gameID)

        // Unblock the reservation, letting T1's now-stale read finally resolve. The
        // deletion itself fails here (as if a concurrent Keychain/profile-store
        // failure had interrupted it) so the token remains intact for T2's own,
        // otherwise-unaffected read to succeed with below.
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest(throwing: TestFailure())
        await staleDeleteTask?.value

        // T2's own (unaffected) token read now resolves and its service call is
        // reached and held at the existing service-level gate.
        await service.waitUntilDeleteGamePending(1)

        // T2 is still genuinely in flight; T1's stale token read must not have
        // cleared T2's own marker.
        #expect(model.gameLifecycleActions[gameID] == .deleting)
        #expect(model.gameLifecycleActionFailures[gameID] == nil)

        await service.resumeOldestDeleteGame(with: .success(()))
        await model.gameLifecycleActionTasks[gameID]?.value
        _ = await cleanupTask.value
    }
}

private extension SessionState {
    var isSignedIn: Bool {
        if case .signedIn = self {
            true
        } else {
            false
        }
    }
}
