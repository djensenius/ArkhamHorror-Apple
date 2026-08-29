@testable import ArkhamHorrorShared
import Testing

/// Regression coverage for durable token-store mutation races: a generation check
/// performed only after an awaited result guards *observable* state, but does not by
/// itself stop an in-flight save/delete (one that ignores cancellation, as a real
/// ``TokenStore``/network dependency may) from completing and corrupting the token
/// store for a profile out of order. These tests gate the token store's `save`/
/// `deleteToken` calls (and, for the unauthorized-deletion race, the auth session's
/// `currentUser` call) themselves — not a stale capability probe — switch away from and
/// back to the same profile (or otherwise supersede with a newer operation), and prove
/// the stale completion neither overwrites/deletes the current token nor leaves the
/// observable session state inconsistent with the token store. Ordering-critical
/// assertions use ``TokenAccessAdmissionCounter`` to deterministically observe an
/// operation's own synchronous admission into `AppModel`'s per-profile
/// `serializedTokenAccess` queue, or await an operation's own task handle, rather than
/// inferring scheduler progress with a fixed number of yields.
extension AppModelTests {
    /// Starts `performAuthOperation` directly (the same production entry point
    /// `beginAuthOperation` schedules) at `generation`, issuing `token` once its save
    /// is reached. Used to construct two genuinely overlapping sign-in saves for the
    /// same profile, which — given full read/write serialization per profile — the
    /// public `signIn()` API's `operation == .idle` guard otherwise makes unreachable.
    private func startAuthOperation(
        on model: AppModel, generation: Int, token: String
    ) -> Task<Void, Never> {
        let credentialEpoch = model.currentCredentialEpoch(for: ServerProfile.hosted.id)
        let globalEpoch = model.currentGlobalCredentialEpoch()
        return Task {
            await model.performAuthOperation(
                profile: .hosted, compatibility: .legacy, epochContext: CredentialOperationContext(
                    generation: generation,
                    credentialEpoch: credentialEpoch,
                    globalEpoch: globalEpoch
                )
            ) { _ in AuthToken(token: token) }
        }
    }

    /// Builds an `AppModel` wired to `tokenStore` with a legacy-fallback capability
    /// probe outcome, awaits its startup flow, and confirms it settles into the
    /// hosted signed-out state — the common starting point several of this file's
    /// races build on. Extracted purely to keep its callers within the project's
    /// function-length lint limit.
    private func legacyFallbackSignedOutModel(
        tokenStore: GatedTokenStore, profiles: [ServerProfile] = []
    ) async -> AppModel {
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: FakeServerProfileStore(profiles: profiles),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        return model
    }

    @Test("A superseded sign-in's save cannot overwrite a newer sign-in's token")
    func supersededSignInSaveCannotOverwriteNewerToken() async {
        let tokenStore = GatedTokenStore()
        let model = await legacyFallbackSignedOutModel(tokenStore: tokenStore)

        // Two overlapping sign-in operations for the same profile, exactly as a
        // profile switch away and back to `.hosted` (or any other operation that
        // advances `generation`) would produce if the injected token store does not
        // itself observe cancellation: an older one, superseded while its own save is
        // still in flight, by a newer one.
        // Deterministically observes each operation's own synchronous admission into
        // the same profile's `serializedTokenAccess` queue, rather than inferring
        // scheduler progress with a fixed number of yields.
        let admissions = TokenAccessAdmissionCounter()
        model.tokenAccessAdmissionHook = admissions.hook

        model.generation += 1
        let staleTask = startAuthOperation(
            on: model, generation: model.generation, token: "first-token"
        )
        await admissions.waitForAdmissions(1, of: ServerProfile.hosted.id)

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
        await admissions.waitForAdmissions(2, of: ServerProfile.hosted.id)

        // The current (newer) operation's save cannot even be attempted yet: it is
        // serialized behind the stale, still-pending save for the same profile. This
        // is a structural guarantee once its own admission is proven — its
        // `serializedTokenAccess` call always awaits the previous tail before ever
        // reaching the token store — not a timing race.
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
        #expect(model.tokenAccessQueues.count == 1)

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
        #expect(model.tokenAccessQueues.isEmpty)
    }

    @Test("A stale sign-out delete after switching back cannot leave signedIn with no token")
    func staleSignOutDeleteReconcilesRatherThanCorruptingState() async {
        let tokenStore = GatedTokenStore(tokens: [ServerProfile.hosted.id: "existing-token"])
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile]),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        let signedIn = SessionState.signedIn(
            profile: .hosted, compatibility: .legacy, user: .sample
        )
        #expect(model.sessionState == signedIn)

        // Deterministically observes admissions into the same profile's
        // `serializedTokenAccess` queue, rather than inferring scheduler progress
        // with a fixed number of yields.
        let admissions = TokenAccessAdmissionCounter()
        model.tokenAccessAdmissionHook = admissions.hook

        // Sign out; the delete suspends mid-flight.
        model.signOut()
        await admissions.waitForAdmissions(1, of: ServerProfile.hosted.id)
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
        // delete, so it cannot yet observe whether the token still exists. Awaiting
        // its own synchronous admission into the queue (rather than a fixed number of
        // yields) proves this deterministically: once admitted, it structurally
        // cannot reach the token store — and so cannot leave `checkingCompatibility`
        // — until the delete it is queued behind resolves.
        await admissions.waitForAdmissions(2, of: ServerProfile.hosted.id)
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
        #expect(model.tokenAccessQueues.isEmpty)
    }

    @Test("A superseded sign-out task cannot enqueue a token deletion after switching back")
    func supersededSignOutBeforeTaskStartCannotDeleteToken() async throws {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "existing-token"])
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile]),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        let signedIn = SessionState.signedIn(
            profile: .hosted, compatibility: .legacy, user: .sample
        )
        #expect(model.sessionState == signedIn)

        // Stay on the main actor for all three calls so the sign-out task cannot begin
        // before both profile selections have advanced the generation.
        model.signOut()
        let staleSignOutTask = model.operationTask
        model.selectProfile(sampleCustomProfile)
        model.selectProfile(.hosted)
        let currentFlowTask = model.flowTask

        await staleSignOutTask?.value
        await currentFlowTask?.value

        #expect(await tokenStore.deleteCallCount == 0)
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "existing-token")
        #expect(model.sessionState == signedIn)
    }

    @Test("A stale unauthorized whoami cannot delete a newer token for the same profile")
    func staleUnauthorizedWhoamiCannotDeleteNewerToken() async throws {
        let tokenStore = FakeTokenStore(tokens: [ServerProfile.hosted.id: "shared-token"])
        let auth = GatedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile]),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
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
        // depends on the same token. Awaiting the stale flow's own task handle is
        // sufficient here (no further settling needed): `deleteUnauthorizedToken` is
        // always awaited inline from within this same task body — never dispatched as
        // a detached/unawaited follow-up — so its generation check having discarded
        // the delete is already fully decided by the time this task completes.
        await auth.resumeOldest(with: .failure(AuthenticationError.unauthorized))
        await staleFlowTask?.value

        #expect(model.sessionState == signedIn)
        #expect(await tokenStore.deleteCallCount == 0)
        let remainingToken = try await tokenStore.token(for: ServerProfile.hosted.id)
        #expect(remainingToken == "shared-token")
    }
}
