@testable import ArkhamHorrorShared
import Testing

private func settle() async {
    for _ in 0 ..< 50 {
        await Task.yield()
    }
}

/// Regression coverage for cancellation-cleanup structural safety: `cancelAuthOperation()`
/// must not merely hide/clear the auth form while a durable token save that has already
/// passed its epoch recheck — or already completed inside the token store — is left to
/// silently apply or persist. See `AppModel+Authentication.swift` (`cancelAuthOperation`,
/// `enqueueCancellationCleanup(for:globalEpoch:)`) and `AppModel.swift`
/// (`serializedTokenAccess(for:epoch:globalEpoch:_:)`).
///
/// These tests use `GatedTokenStore` to suspend a save at two distinct points: (a)
/// *before* the durable mutation is applied at all (still fully in-flight inside the
/// token store), and (b) *after* the mutation has already been applied to storage but
/// before the suspended `save`/`deleteToken` call itself has returned control to its
/// caller. In both cases, cancellation must still result in the canceled token being
/// durably deleted, never left behind for a later launch to silently trust.
extension AppModelTests {
    @Test(
        """
        Cancelling while a save is suspended inside the token store, after its epoch \
        check has already passed, still deletes the token it durably applies
        """
    )
    func cancelDuringInFlightSaveStillDeletesToken() async throws {
        let tokenStore = GatedTokenStore()
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth
        )
        await model.flowTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "cancelled-token") }
        // The save has already passed its epoch recheck inside
        // `serializedTokenAccess(for:epoch:globalEpoch:_:)` by the time it reaches the
        // token store at all, so once it is visible here as pending, cancellation can no
        // longer prevent it from durably applying on its own.
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "cancelled-token", profileID: ServerProfile.hosted.id)]
        )

        model.cancelAuthOperation()
        #expect(model.operation == .idle)
        #expect(model.operationFailure == nil)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        // Let the in-flight save complete: it durably applies, since it already passed
        // its epoch check before cancellation invalidated it.
        await tokenStore.resumeOldest()
        await settle()
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "cancelled-token")

        // The cancellation cleanup delete — synchronously enqueued behind this save's
        // tail by `cancelAuthOperation()` — can only reach the token store once the save
        // it was queued behind actually finishes.
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() == [.delete(profileID: ServerProfile.hosted.id)]
        )
        await tokenStore.resumeOldest()
        await settle()

        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)
        // Cancellation must remain silent: no user-facing failure from cleanup succeeding.
        #expect(model.operationFailure == nil)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }

    @Test(
        """
        Cancelling after a save has already applied its mutation, but before the \
        suspended call returns, still deletes the token
        """
    )
    func cancelAfterSaveAppliesButBeforeReturnStillDeletesToken() async throws {
        let tokenStore = GatedTokenStore()
        await tokenStore.setSuspendAfterApply(true)
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth
        )
        await model.flowTask?.value

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "cancelled-token") }
        await tokenStore.waitUntilPending(1)
        // Let the save proceed past its (pre-apply) epoch-recheck gate: it applies the
        // mutation to storage immediately, then suspends a second time before returning.
        await tokenStore.resumeOldest()
        await tokenStore.waitUntilPostApplyPending(1)

        // The mutation has already taken effect — the token is durably present — even
        // though the `save` call itself has not yet returned to its caller.
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "cancelled-token")

        model.cancelAuthOperation()
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        // Let the suspended `save` call finally return.
        await tokenStore.resumeOldestPostApply()

        // The cleanup delete, queued behind this save's tail before cancellation
        // returned, now removes the token it could not have prevented from applying.
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() == [.delete(profileID: ServerProfile.hosted.id)]
        )
        await tokenStore.resumeOldest()
        await tokenStore.waitUntilPostApplyPending(1)
        await tokenStore.resumeOldestPostApply()

        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)
        #expect(model.operationFailure == nil)
    }

    @Test(
        """
        A cancelled save's cleanup cannot overtake, or be overtaken by, an \
        immediately following legitimate sign-in for the same profile
        """
    )
    func cancelImmediatelyFollowedByNewAuthPreservesOrdering() async throws {
        let tokenStore = GatedTokenStore()
        let auth = ScriptedAuthenticating(
            authenticateResult: .success(AuthToken(token: "fresh-token")),
            currentUserResult: .success(.sample)
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth
        )
        await model.flowTask?.value

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "stale-token") }
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "stale-token", profileID: ServerProfile.hosted.id)]
        )

        model.cancelAuthOperation()
        // A fresh, legitimate sign-in for the same profile begins immediately after
        // cancellation — its save must be queued strictly behind both the stale save
        // still in flight and the cleanup delete cancellation enqueues, never able to
        // race ahead of either.
        model.signIn(AuthenticationCredentials(email: "ashcan@example.com", password: "secret"))
        #expect(model.operation == .signingIn)

        // Nothing else can have reached the token store yet: the fresh sign-in's own
        // save is queued behind the cleanup delete, which is itself queued behind the
        // still-suspended stale save.
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "stale-token", profileID: ServerProfile.hosted.id)]
        )

        // Let the stale save durably apply (it already passed its epoch check before
        // cancellation).
        await tokenStore.resumeOldest()
        await settle()
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "stale-token")

        // The cleanup delete can now reach the token store.
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() == [.delete(profileID: ServerProfile.hosted.id)]
        )
        await tokenStore.resumeOldest()
        await settle()
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == nil)

        // Only now can the fresh sign-in's own save reach the token store.
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "fresh-token", profileID: ServerProfile.hosted.id)]
        )
        await tokenStore.resumeOldest()
        // The save resolving only unblocks `serializedTokenAccess`'s continuation;
        // the fresh sign-in's own `operationTask` still needs to be awaited to
        // observe its subsequent `sessionState` transition to `.signedIn`.
        await model.operationTask?.value

        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "fresh-token")
        #expect(
            model.sessionState ==
                .signedIn(profile: .hosted, compatibility: .legacy, user: .sample)
        )
        #expect(model.operationFailure == nil)
    }
}
