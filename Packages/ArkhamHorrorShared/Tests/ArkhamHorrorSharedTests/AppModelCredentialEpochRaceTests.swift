@testable import ArkhamHorrorShared
import Testing

/// Regression coverage for the per-profile credential epoch: an endpoint edit or
/// removal invalidates a profile's credential epoch *before* enqueueing its token
/// deletion, and every queued read/save/delete rechecks that epoch inside the
/// serialized closure immediately before touching the Keychain (see
/// `AppModel+Authentication.swift`, `AppModel+Compatibility.swift`, and
/// `AppModel+ProfileManagement+Async.swift`). These tests prove a same-profile
/// sign-in whose save is enqueued before, during, or racing a concurrent endpoint
/// edit/removal can never durably resurrect a token for the profile's old (or a
/// stale) origin, in any completion order.
extension AppModelTests {
    /// Starts `performAuthOperation` for an arbitrary profile at `generation`,
    /// capturing its credential epoch synchronously (mirroring `beginAuthOperation`,
    /// which reads the epoch before any `await`), issuing `token` once its save is
    /// reached.
    private func startAuthOperation(
        on model: AppModel, profile: ServerProfile, generation: Int, token: String
    ) -> Task<Void, Never> {
        let credentialEpoch = model.currentCredentialEpoch(for: profile.id)
        let globalEpoch = model.currentGlobalCredentialEpoch()
        return Task {
            await model.performAuthOperation(
                profile: profile, compatibility: .legacy, epochContext: CredentialOperationContext(
                    generation: generation,
                    credentialEpoch: credentialEpoch,
                    globalEpoch: globalEpoch
                )
            ) { _ in AuthToken(token: token) }
        }
    }

    // MARK: - Credential-epoch races against concurrent endpoint edits/removals

    /// The primary race this finding closes: a sign-in's save reaches the durable
    /// mutation boundary *after* a concurrent endpoint edit for the very same profile
    /// has already invalidated its credential epoch and deleted its token. The
    /// generation guard alone cannot stop this — the edit does not touch
    /// `model.generation` unless the edited profile is currently selected — so only the
    /// credential-epoch recheck inside the serialized closure can.
    @Test("A sign-in's save enqueued behind a concurrent endpoint edit cannot resurrect the token")
    func signInSaveBehindEndpointEditCannotResurrectToken() async throws {
        let tokenStore = FakeTokenStore()
        let auth = GatedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile]),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        // A sign-in for the custom profile captures its epoch now, authenticates
        // instantly, then suspends on whoami.
        model.generation += 1
        let signInTask = startAuthOperation(
            on: model, profile: sampleCustomProfile, generation: model.generation,
            token: "stale-token"
        )
        await auth.waitUntilPending(1)

        // While the sign-in's whoami is still in flight, the same profile's endpoint
        // is edited: this bumps its credential epoch and deletes its token before the
        // edit is durably persisted.
        let edited = try ServerProfile.custom(
            id: sampleCustomProfile.id,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://edited-host.example.com"
        )
        model.updateCustomProfile(
            sampleCustomProfile, displayName: edited.displayName,
            rawURL: edited.baseURL.absoluteString
        )
        await model.profileManagementTask?.value

        // Only now does the stale sign-in's whoami resolve successfully.
        await auth.resumeOldest(with: .success(.sample))
        await signInTask.value

        // No further settling is needed: `performAuthOperation`'s save (or, here, its
        // discarded epoch-mismatch attempt) is always awaited inline before the task
        // returns — never dispatched as a detached/unawaited follow-up — so
        // `signInTask.value` completing already fully decides this.
        // The stale save must never have durably applied.
        let finalToken = try await tokenStore.token(for: sampleCustomProfile.id)
        #expect(finalToken == nil)
        // The epoch mismatch must not be surfaced as a user-facing failure.
        #expect(model.operationFailure == nil)
    }

    /// The reverse ordering: the sign-in's save is already suspended, mid-flight,
    /// *before* the concurrent endpoint edit begins, so the edit's own delete is
    /// enqueued strictly behind it in the same profile's serialized queue. Both
    /// operations captured a credential epoch that matched at their own enqueue time,
    /// so both durably apply — the edit's delete, being last, is the correct final
    /// word, leaving no token for the edited profile.
    @Test("An endpoint edit's delete queued behind an in-flight save still removes the token")
    func endpointEditDeleteQueuedBehindInFlightSaveStillRemovesToken() async throws {
        let tokenStore = GatedTokenStore()
        let auth = ScriptedAuthenticating(currentUserResult: .success(.sample))
        let model = AppModel(
            profileStore: FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile]),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        model.generation += 1
        // Deterministically observes each operation's own synchronous admission into
        // the same profile's `serializedTokenAccess`/`enqueueCancellationCleanup`
        // queue, rather than inferring scheduler progress with a fixed number of
        // yields.
        let admissions = TokenAccessAdmissionCounter()
        model.tokenAccessAdmissionHook = admissions.hook
        let signInTask = startAuthOperation(
            on: model, profile: sampleCustomProfile, generation: model.generation,
            token: "new-token"
        )
        await admissions.waitForAdmissions(1, of: sampleCustomProfile.id)
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "new-token", profileID: sampleCustomProfile.id)]
        )

        // Edit the same profile's endpoint while that save is still suspended. Its
        // delete is enqueued strictly behind the pending save.
        let edited = try ServerProfile.custom(
            id: sampleCustomProfile.id,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://edited-host.example.com"
        )
        model.updateCustomProfile(
            sampleCustomProfile, displayName: edited.displayName,
            rawURL: edited.baseURL.absoluteString
        )
        await admissions.waitForAdmissions(2, of: sampleCustomProfile.id)
        // The edit's delete is chained behind the still-pending save (it awaits the
        // save's own scheduled task before even reaching the token store), so it
        // cannot register as pending until the save is let through. This is a
        // structural guarantee once its own admission is proven, not a timing race.
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "new-token", profileID: sampleCustomProfile.id)]
        )

        // Let the save durably apply (it captured its epoch before the edit
        // invalidated it, so it is not stale).
        await tokenStore.resumeOldest()
        await signInTask.value

        // Only now can the edit's delete reach the token store and register as
        // pending.
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.delete(profileID: sampleCustomProfile.id)]
        )

        // Let the edit's delete durably apply next.
        await tokenStore.resumeOldest()
        await model.profileManagementTask?.value

        let finalTokens = await tokenStore.snapshotTokens()
        #expect(finalTokens[sampleCustomProfile.id] == nil)
    }

    /// Out-of-order network completion combined with newer-legitimate-token
    /// preservation: a stale sign-in's whoami resolves only *after* both a concurrent
    /// endpoint edit and a fresh, current sign-in for the (now edited) profile have
    /// fully completed and durably saved a new token. The stale completion must not
    /// overwrite that newer, currently valid token.
    @Test("A stale sign-in's out-of-order completion cannot overwrite a newer legitimate token")
    func staleSignInOutOfOrderCompletionCannotOverwriteNewerToken() async throws {
        let tokenStore = FakeTokenStore()
        let auth = GatedAuthenticating()
        let model = AppModel(
            profileStore: FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile]),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        // The stale sign-in captures its epoch now, then suspends on whoami.
        model.generation += 1
        let staleTask = startAuthOperation(
            on: model, profile: sampleCustomProfile, generation: model.generation,
            token: "stale-token"
        )
        await auth.waitUntilPending(1)

        // The endpoint is edited while the stale sign-in's whoami is still pending.
        let edited = try ServerProfile.custom(
            id: sampleCustomProfile.id,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://edited-host.example.com"
        )
        model.updateCustomProfile(
            sampleCustomProfile, displayName: edited.displayName,
            rawURL: edited.baseURL.absoluteString
        )
        await model.profileManagementTask?.value
        let updatedProfile = try #require(model.profiles.first { $0.id == sampleCustomProfile.id })

        // A fresh, current sign-in for the (now edited) profile begins, capturing a
        // freshly current epoch, and also suspends on whoami (behind the stale one, in
        // this shared gated fake).
        model.generation += 1
        let freshTask = startAuthOperation(
            on: model, profile: updatedProfile, generation: model.generation, token: "fresh-token"
        )
        await auth.waitUntilPending(2)

        // Resolve the fresh sign-in first: it durably saves its token.
        await auth.resumeNewest(with: .success(.sample))
        await freshTask.value
        #expect(try await tokenStore.token(for: updatedProfile.id) == "fresh-token")

        // Only now does the stale sign-in's whoami resolve, out of order. Awaiting
        // the stale task's own handle is sufficient here (no further settling
        // needed): its save (or discarded epoch-mismatch attempt) is always awaited
        // inline before the task returns, per `performAuthOperation`.
        await auth.resumeOldest(with: .success(.sample))
        await staleTask.value

        #expect(try await tokenStore.token(for: updatedProfile.id) == "fresh-token")
    }
}
