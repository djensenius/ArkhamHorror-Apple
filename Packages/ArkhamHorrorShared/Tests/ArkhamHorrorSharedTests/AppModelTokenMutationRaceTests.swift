@testable import ArkhamHorrorShared
import Testing

/// Yields repeatedly so any unserialized (buggy) concurrent token-store access has
/// ample opportunity to actually run before a test asserts that it did not — a single
/// `waitUntilPending`/`await` is not enough to rule this out, since it returns as soon
/// as its own threshold is already satisfied without waiting to see whether a second,
/// unserialized access also reaches the gate.
private func settle() async {
    for _ in 0 ..< 50 {
        await Task.yield()
    }
}

/// Regression coverage for durable token-store mutation races: a generation check
/// performed only after an awaited result guards *observable* state, but does not by
/// itself stop an in-flight save/delete (one that ignores cancellation, as a real
/// ``TokenStore``/network dependency may) from completing and corrupting the token
/// store for a profile out of order. These tests gate the token store's `save`/
/// `deleteToken` calls (and, for the unauthorized-deletion race, the auth session's
/// `currentUser` call) themselves — not a stale capability probe — switch away from and
/// back to the same profile (or otherwise supersede with a newer operation), and prove
/// the stale completion neither overwrites/deletes the current token nor leaves the
/// observable session state inconsistent with the token store.
extension AppModelTests {
    /// Starts `performAuthOperation` directly (the same production entry point
    /// `beginAuthOperation` schedules) at `generation`, issuing `token` once its save
    /// is reached. Used to construct two genuinely overlapping sign-in saves for the
    /// same profile, which — given full read/write serialization per profile — the
    /// public `signIn()` API's `operation == .idle` guard otherwise makes unreachable.
    private func startAuthOperation(
        on model: AppModel, generation: Int, token: String
    ) -> Task<Void, Never> {
        Task {
            await model.performAuthOperation(
                profile: .hosted, compatibility: .legacy, generation: generation
            ) { _ in AuthToken(token: token) }
        }
    }

    @Test("A superseded sign-in's save cannot overwrite a newer sign-in's token")
    func supersededSignInSaveCannotOverwriteNewerToken() async {
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

        // Two overlapping sign-in operations for the same profile, exactly as a
        // profile switch away and back to `.hosted` (or any other operation that
        // advances `generation`) would produce if the injected token store does not
        // itself observe cancellation: an older one, superseded while its own save is
        // still in flight, by a newer one.
        model.generation += 1
        let staleTask = startAuthOperation(
            on: model, generation: model.generation, token: "first-token"
        )

        // The stale operation's save suspends, mid-flight.
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "first-token", profileID: ServerProfile.hosted.id)]
        )

        model.generation += 1
        let currentTask = startAuthOperation(
            on: model, generation: model.generation, token: "second-token"
        )

        // The current (newer) operation's save cannot even be attempted yet: it is
        // serialized behind the stale, still-pending save for the same profile. Give
        // it ample opportunity to run (as it would if unserialized) before checking.
        await settle()
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "first-token", profileID: ServerProfile.hosted.id)]
        )

        // Resolve the stale save. Its own generation check then discards its
        // completion rather than mutating state, but the serialized queue now lets the
        // current save proceed next.
        await tokenStore.resumeOldest()
        await staleTask.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "second-token", profileID: ServerProfile.hosted.id)]
        )
        await tokenStore.resumeOldest()
        await currentTask.value

        let expected = SessionState.signedIn(
            profile: .hosted, compatibility: .legacy, user: .sample
        )
        #expect(model.sessionState == expected)
        #expect(model.operationFailure == nil)
        let finalTokens = await tokenStore.snapshotTokens()
        #expect(finalTokens[ServerProfile.hosted.id] == "second-token")
    }

    @Test("A stale sign-out delete after switching back cannot leave signedIn with no token")
    func staleSignOutDeleteReconcilesRatherThanCorruptingState() async {
        let tokenStore = GatedTokenStore(tokens: [ServerProfile.hosted.id: "existing-token"])
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile]),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth
        )
        await model.flowTask?.value
        let signedIn = SessionState.signedIn(
            profile: .hosted, compatibility: .legacy, user: .sample
        )
        #expect(model.sessionState == signedIn)

        // Sign out; the delete suspends mid-flight.
        model.signOut()
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() == [.delete(profileID: ServerProfile.hosted.id)]
        )

        // Switch away and back to the same profile while the delete is still pending.
        model.selectProfile(sampleCustomProfile)
        await model.flowTask?.value
        model.selectProfile(.hosted)
        let currentFlowTask = model.flowTask

        // The restored flow's token read must be serialized behind the pending
        // delete, so it cannot yet observe whether the token still exists. Give it
        // ample opportunity to race ahead (as it would if unserialized) before
        // checking that it has not.
        await settle()
        #expect(model.sessionState == .checkingCompatibility(profile: .hosted))

        // Resolve the stale delete. Its own generation check discards its completion
        // rather than mutating observable state, but its effect (removing the token)
        // is now durably applied before the queued, current-generation read runs next.
        await tokenStore.resumeOldest()
        await currentFlowTask?.value

        // The current flow correctly observes no token (rather than a stale
        // "existing-token" value) and reports signedOut — never a signedIn state whose
        // backing token has silently vanished.
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        let finalTokens = await tokenStore.snapshotTokens()
        #expect(finalTokens[ServerProfile.hosted.id] == nil)
    }

    @Test("A stale unauthorized whoami cannot delete a newer token for the same profile")
    func staleUnauthorizedWhoamiCannotDeleteNewerToken() async throws {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "shared-token"])
        let auth = GatedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile]),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth
        )

        // The launch flow's whoami call is now suspended, mid-flight (stale, gen 1).
        await auth.waitUntilPending(1)
        let staleFlowTask = model.flowTask

        // Switch away and back to the same profile: a fresh flow re-reads the same
        // token and issues its own (current-generation) whoami call, which also
        // suspends.
        model.selectProfile(sampleCustomProfile)
        await model.flowTask?.value
        model.selectProfile(.hosted)
        let currentFlowTask = model.flowTask
        await auth.waitUntilPending(2)

        // Resolve the newer (current-generation) call first, successfully.
        await auth.resumeNewest(with: .success(.sample))
        await currentFlowTask?.value
        let signedIn = SessionState.signedIn(
            profile: .hosted, compatibility: .legacy, user: .sample
        )
        #expect(model.sessionState == signedIn)

        // Now resolve the stale call with `.unauthorized`. Its generation check (added
        // immediately before deletion would otherwise be requested) must stop it from
        // ever calling `deleteToken`, since a newer, currently signed-in generation now
        // depends on the same token.
        await auth.resumeOldest(with: .failure(AuthenticationError.unauthorized))
        await staleFlowTask?.value
        await settle()

        #expect(model.sessionState == signedIn)
        #expect(await tokenStore.deleteCallCount == 0)
        let remainingToken = try await tokenStore.token(for: ServerProfile.hosted.id)
        #expect(remainingToken == "shared-token")
    }
}
