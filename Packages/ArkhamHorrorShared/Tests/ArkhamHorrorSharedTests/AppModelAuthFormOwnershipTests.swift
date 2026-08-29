@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic multiwindow coverage for sign-in/registration form ownership:
/// `AppModel` is shared process-wide across every window (see `AppModel.swift`'s own
/// documentation and `AuthenticationView.swift`'s), so two windows can each have a
/// `SignInView`/`RegisterView` open at once. Only the exact form that started an
/// attempt (identified by the opaque `UUID` `beginAuthOperation(_:issueToken:)` /
/// `signIn(_:)` / `register(_:)` return to their caller) may cancel it via
/// `cancelAuthOperation(ownedBy:)` — a different window's Cancel tap must leave
/// someone else's still-wanted operation completely untouched, only ever affecting
/// its own local presentation. These tests simulate multiple preexisting
/// windows/forms by driving the one shared `AppModel` with independent captured
/// attempt identities, exactly the seam `SignInView`/`RegisterView` themselves are
/// built on (see `AuthenticationView.swift`'s `ownedAttemptID`).
extension AppModelTests {
    @Test(
        """
        Both forms preexist before either submits: after window A starts a sign-in, \
        window B's Cancel (which never itself submitted) reports safe-to-dismiss but \
        leaves A's operation/task/generation completely intact
        """
    )
    func nonOwnerCancelLeavesActiveOperationIntact() async throws {
        let auth = GatedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        // Window A starts a sign-in and remembers its own attempt identity, exactly
        // as `SignInView.submit()` captures `signIn(_:)`'s return into local state.
        let attemptA = model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "a-token") }
        try #require(attemptA != nil)
        await auth.waitUntilPending(1)
        #expect(model.operation == .signingIn)
        let generationBeforeBCancel = model.generation
        let taskBeforeBCancel = model.operationTask != nil

        // Window B's own form never submitted anything, so its remembered attempt ID
        // is `nil` — exactly like a freshly opened, still-idle `SignInView`.
        let bCancelled = model.cancelAuthOperation(ownedBy: nil)

        // B is told it's safe to dismiss its own (never-submitted) form...
        #expect(bCancelled == true)
        // ...but A's genuinely active operation is entirely untouched: same task,
        // same generation, still signing in, no spurious failure or state change.
        #expect(model.operation == .signingIn)
        #expect(model.generation == generationBeforeBCancel)
        #expect((model.operationTask != nil) == taskBeforeBCancel)
        #expect(model.operationFailure == nil)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        // A's own cancel (using its own remembered attempt ID) still works normally,
        // and the underlying dependency resolving late does not let it sign in.
        #expect(model.cancelAuthOperation(ownedBy: attemptA) == true)
        #expect(model.operation == .idle)
        #expect(model.operationTask == nil)
        await auth.resumeOldest(with: .success(.sample))
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }

    @Test(
        """
        A stale attemptID from a window's own earlier, already-cancelled attempt \
        cannot cancel a different, newer operation reusing the same profile/kind
        """
    )
    func staleAttemptCannotCancelNewerOperation() async throws {
        let auth = GatedAuthenticating()
        let tokenStore = FakeTokenStore()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        // Window A starts a sign-in, then cancels it itself (a legitimate, resolved
        // attempt — not merely a failure), freeing `operation` back to `.idle`.
        let attemptA = model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "a-token") }
        await auth.waitUntilPending(1)
        #expect(model.cancelAuthOperation(ownedBy: attemptA) == true)
        #expect(model.operation == .idle)
        await auth.resumeOldest(with: .success(.sample))

        // Window C starts a brand-new sign-in for the very same profile/operation
        // kind, still signed out.
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        let attemptC = model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "c-token") }
        try #require(attemptC != nil)
        try #require(attemptC != attemptA)
        await auth.waitUntilPending(1)
        #expect(model.operation == .signingIn)
        let generationBeforeStaleCancel = model.generation
        let taskBeforeStaleCancel = model.operationTask != nil

        // Window A, still holding its own stale (already-resolved) attempt ID —
        // for example a delayed, redundant Cancel tap arriving late — cannot cancel
        // C's brand-new operation.
        let staleCancelled = model.cancelAuthOperation(ownedBy: attemptA)
        #expect(staleCancelled == true)
        #expect(model.operation == .signingIn)
        #expect(model.generation == generationBeforeStaleCancel)
        #expect((model.operationTask != nil) == taskBeforeStaleCancel)
        #expect(model.operationFailure == nil)

        // C can still cancel its own, genuinely active attempt normally.
        #expect(model.cancelAuthOperation(ownedBy: attemptC) == true)
        #expect(model.operation == .idle)
        await auth.resumeOldest(with: .success(.sample))
        #expect(await tokenStore.saveCallCount == 0)
    }

    @Test(
        """
        A stale attemptID left over after this window's own operation successfully \
        completes cannot cancel a later operation reusing the same profile/kind
        """
    )
    func staleAttemptAfterSuccessCannotCancelLaterOperation() async throws {
        let tokenStore = FakeTokenStore()
        let auth = GatedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        // Window A signs in fully and successfully.
        let attemptA = model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "a-token") }
        try #require(attemptA != nil)
        await auth.waitUntilPending(1)
        await auth.resumeOldest(with: .success(.sample))
        await model.operationTask?.value
        #expect(
            model.sessionState ==
                .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )

        // A late, idempotent dismissal from A's own already-succeeded form must not
        // undo the sign-in.
        #expect(model.cancelAuthOperation(ownedBy: attemptA) == true)
        #expect(
            model.sessionState ==
                .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )

        // Sign back out to reach `.signedOut` again so a second sign-in is possible.
        model.signOut()
        await model.operationTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        // A brand-new window (or the same one, reopened) starts a fresh sign-in for
        // the same profile.
        let attemptC = model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "c-token") }
        try #require(attemptC != nil)
        try #require(attemptC != attemptA)
        await auth.waitUntilPending(1)

        // A's long-stale, already-succeeded attempt ID must not be able to reach into
        // this entirely different, later operation.
        let staleCancelled = model.cancelAuthOperation(ownedBy: attemptA)
        #expect(staleCancelled == true)
        #expect(model.operation == .signingIn)
        #expect(model.operationFailure == nil)

        #expect(model.cancelAuthOperation(ownedBy: attemptC) == true)
        #expect(model.operation == .idle)
        await auth.resumeOldest(with: .success(.sample))
    }

    @Test(
        """
        A rejected sign-in's failure is attributed to its own attempt: it never \
        matches a pre-opened, never-submitted window's own (nil) owned attempt ID
        """
    )
    func rejectedSignInFailureIsAttributedToOwningAttemptOnly() async throws {
        let auth = GatedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        // Window A submits and is mid-whoami; window B is a second, pre-existing
        // form that never itself submitted, exactly like `SignInView`'s
        // `ownedAttemptID` before `submit()` is ever called.
        let attemptA = model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "a-token") }
        try #require(attemptA != nil)
        let bOwnedAttemptID: UUID? = nil
        await auth.waitUntilPending(1)

        await auth.resumeOldest(with: .failure(AuthenticationError.unauthorized))
        await model.operationTask?.value

        // A's own rejection is attributed to exactly its attempt.
        #expect(model.authFailure?.attemptID == attemptA)
        guard case .authentication(.unauthorized) = model.authFailure?.failure else {
            Issue.record(
                """
                Expected .authentication(.unauthorized), got \
                \(String(describing: model.authFailure))
                """
            )
            return
        }

        // The exact condition `SignInView`/`RegisterView` render on: B's own
        // (never-submitted) owned attempt ID is `nil`, so it can never equal A's
        // real attempt ID here — B must not render A's failure.
        let bWouldRenderAsOwnFailure =
            bOwnedAttemptID != nil && model.authFailure?.attemptID == bOwnedAttemptID
        #expect(bWouldRenderAsOwnFailure == false)

        #expect(model.operation == .idle)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }

    @Test(
        """
        A's stale, already-interrupted operation's late whoami resolution cannot \
        overwrite C's own newer, unrelated failure once C has started
        """
    )
    func staleInterruptedAttemptCannotOverwriteNewerAttemptsFailure() async throws {
        let auth = GatedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        // Window A submits and is mid-whoami when its own window is dismissed via
        // its own Cancel — a legitimate interruption, not a failure of A's own.
        let attemptA = model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "a-token") }
        try #require(attemptA != nil)
        await auth.waitUntilPending(1)
        #expect(model.cancelAuthOperation(ownedBy: attemptA) == true)
        #expect(model.operation == .idle)
        #expect(model.authFailure == nil)

        // Window C starts an entirely new sign-in for the same profile/kind, whose
        // own `issueToken` step itself fails synchronously (a different failure
        // category than A's).
        let attemptC = model.beginAuthOperation(.signingIn) { _ in
            throw AuthenticationError.unauthorized
        }
        try #require(attemptC != nil)
        try #require(attemptC != attemptA)
        await model.operationTask?.value

        #expect(model.authFailure?.attemptID == attemptC)
        let failureAfterC = model.authFailure

        // A's stale whoami, suspended this whole time, only now resolves late. Its
        // captured generation was already superseded by both A's own interruption
        // and C's subsequent start, so this must not touch `authFailure`,
        // `operation`, or `sessionState` at all.
        await auth.resumeOldest(with: .success(.sample))

        #expect(model.authFailure?.attemptID == failureAfterC?.attemptID)
        #expect(model.operation == .idle)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }
}
