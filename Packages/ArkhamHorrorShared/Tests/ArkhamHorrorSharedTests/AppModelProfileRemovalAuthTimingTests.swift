@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Two additional, stronger timing-boundary proofs for the single-reservation
/// auth-interruption transaction (``AppModel/reserveCleanupInterruptingActiveAuth(for:)``)
/// covered from a different angle in `AppModelProfileRemovalAuthInterruptionTests.swift` —
/// split into its own file purely to stay within the file-length lint limit.
///
/// Both target the exact moments the transaction's guarantees matter most:
///
/// 1. The instant *before* an active sign-in/registration's own task has even begun
///    running — before it has entered ``AppModel/resolvePendingCleanup(for:)`` or
///    captured its credential epoch — proving the interruption (generation bump,
///    credential-epoch bump, task cancellation) is not merely eventually consistent
///    but complete synchronously, in the very same call, before any of the
///    mutation's own async continuation ever runs.
/// 2. The instant a save for the profile being mutated has already reached the
///    durable token-store boundary (dispatched into ``GatedTokenStore`` and
///    suspended there, past its own epoch capture), proving the reservation still
///    protects against it: exactly one durable mark, no metadata committed before
///    cleanup, the queued cleanup delete only actually reaching the store once that
///    save resolves, and no orphaned token or resurrected session for the
///    removed/edited profile.
extension AppModelTests {
    private func makeModel(
        tokenStore: any TokenStore,
        auth: any AppAuthenticating,
        cleanupStore: FakeTokenCleanupPendingStore
    ) -> AppModel {
        AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [.hosted, sampleCustomProfile], selectedID: sampleCustomProfile.id
            ),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
    }

    @Test(
        """
        Removing the selected profile before its active sign-in has run any part \
        of its own task body advances generation and the credential epoch, cancels \
        its task, and reserves cleanup — all synchronously, before the async \
        removal continuation itself runs
        """
    )
    func removingSelectedProfileBeforeAuthTaskRunsInterruptsSynchronously() async {
        let tokenStore = FakeTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = makeModel(
            tokenStore: tokenStore,
            auth: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupStore: cleanupStore
        )
        await model.flowTask?.value
        #expect(
            model.sessionState == .signedOut(profile: sampleCustomProfile, compatibility: .legacy)
        )
        let generationBeforeSignIn = model.generation
        let epochBeforeSignIn = model.currentCredentialEpoch(for: sampleCustomProfile.id)

        // Synchronously installs `operation`/`operationTask`/`generation`, but the
        // task's own body — which would call `resolvePendingCleanup` and capture the
        // credential epoch — cannot have run any part of itself yet: this MainActor
        // context has not suspended (awaited anything) since the call returned, and
        // Swift's cooperative scheduler cannot preempt synchronous actor-isolated
        // code to run a newly spawned, unstructured `Task`.
        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        #expect(model.operation == .signingIn)
        #expect(model.generation == generationBeforeSignIn + 1)
        let staleOperationTask = model.operationTask
        #expect(staleOperationTask != nil)

        // Still the same synchronous turn.
        model.removeCustomProfile(sampleCustomProfile)

        // Asserted immediately, before awaiting anything the removal itself started:
        // the entire interruption transaction — generation, credential epoch,
        // operation/task, and the durable reservation — already completed
        // synchronously inside `removeCustomProfile`. If the generation bump were
        // ever removed from `reserveCleanupInterruptingActiveAuth(for:)`, this
        // specific assertion would fail here even though the credential-epoch bump
        // and eventual hosted fallback would otherwise still make the rest of this
        // test pass.
        #expect(model.generation == generationBeforeSignIn + 2)
        #expect(model.currentCredentialEpoch(for: sampleCustomProfile.id) == epochBeforeSignIn + 1)
        #expect(model.operationTask == nil)
        #expect(model.operation == .idle)
        #expect(model.operationFailure == nil)
        #expect(cleanupStore.markPendingCallCountSnapshot() == 1)
        #expect(cleanupStore.snapshotPendingIDs() == [sampleCustomProfile.id])
        // Metadata has not yet half-applied: the async removal continuation has not
        // run at all yet.
        #expect(model.profiles == [.hosted, sampleCustomProfile])
        #expect(model.profileManagementOperation == .removing(sampleCustomProfile.id))

        // Now let the stale auth task actually run its body for the first time, and
        // let the removal (and its hosted fallback) run to completion. With no
        // further gating, both are ready to run and their exact relative completion
        // order is an implementation detail — what matters is that the stale task
        // contributed no mutation of its own (proven by the combined counts/state
        // below) once everything has settled.
        await staleOperationTask?.value
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(model.profiles == [.hosted])
        #expect(model.selectedProfile == .hosted)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        // The stale auth task never reached (or durably saved via) `currentUser`/the
        // token store, and the removal's single reservation was never re-marked by
        // it: exactly one save-free, one-mark, one-delete outcome for the whole flow.
        #expect(await tokenStore.saveCallCount == 0)
        #expect(await tokenStore.deleteCallCount == 1)
        #expect(model.operationFailure == nil)
        #expect(cleanupStore.markPendingCallCountSnapshot() == 1)
        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
    }

    @Test(
        """
        Editing the selected profile's endpoint before its active registration has \
        run any part of its own task body advances generation and the credential \
        epoch, cancels its task, and reserves cleanup — all synchronously
        """
    )
    func editingSelectedProfileEndpointBeforeAuthTaskRunsInterruptsSynchronously() async {
        let tokenStore = FakeTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = makeModel(
            tokenStore: tokenStore,
            auth: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupStore: cleanupStore
        )
        await model.flowTask?.value
        let generationBeforeRegister = model.generation
        let epochBeforeRegister = model.currentCredentialEpoch(for: sampleCustomProfile.id)

        model.beginAuthOperation(.registering) { _ in AuthToken(token: "issued-token") }
        #expect(model.operation == .registering)
        #expect(model.generation == generationBeforeRegister + 1)
        let staleOperationTask = model.operationTask

        model.updateCustomProfile(
            sampleCustomProfile,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://new-host.example.com"
        )

        #expect(model.generation == generationBeforeRegister + 2)
        #expect(
            model.currentCredentialEpoch(for: sampleCustomProfile.id) == epochBeforeRegister + 1
        )
        #expect(model.operationTask == nil)
        #expect(model.operation == .idle)
        #expect(cleanupStore.markPendingCallCountSnapshot() == 1)
        // Metadata has not yet half-applied.
        #expect(model.profiles == [.hosted, sampleCustomProfile])

        // Now let the stale auth task and the edit's own async continuation run to
        // completion; their relative order is an implementation detail once neither
        // is gated further.
        await staleOperationTask?.value
        await model.profileManagementTask?.value
        await model.flowTask?.value

        let editedProfile = model.profiles.first { $0.id == sampleCustomProfile.id }
        #expect(editedProfile?.baseURL.host == "new-host.example.com")
        #expect(
            model.sessionState ==
                .signedOut(profile: editedProfile ?? .hosted, compatibility: .legacy)
        )
        // The stale registration task made zero mutation of its own — it never
        // reached (or durably saved via) `currentUser`/the token store — and the
        // edit's single reservation was never re-marked by it.
        #expect(await tokenStore.saveCallCount == 0)
        #expect(cleanupStore.markPendingCallCountSnapshot() == 1)
    }

    @Test(
        """
        Removing the selected profile while its sign-in's save is already \
        dispatched into the durable token store reserves cleanup exactly once \
        without committing metadata first, only actually deletes the token once \
        that in-flight save resolves, and never resurrects a signed-in session or \
        orphans the token for the removed profile
        """
    )
    func removingSelectedProfileWhileSaveAtDurableBoundaryQueuesCleanupBehindIt() async {
        let tokenStore = GatedTokenStore()
        let auth = GatedAuthenticating()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = makeModel(tokenStore: tokenStore, auth: auth, cleanupStore: cleanupStore)
        await model.flowTask?.value
        #expect(
            model.sessionState == .signedOut(profile: sampleCustomProfile, compatibility: .legacy)
        )

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        let staleOperationTask = model.operationTask
        await auth.resumeOldest(with: .success(.sample))

        // Wait until the save has actually been dispatched into the durable token
        // store and is suspended there, past its own epoch capture — the exact
        // durable boundary this test targets.
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() ==
                [.save(token: "issued-token", profileID: sampleCustomProfile.id)]
        )

        model.removeCustomProfile(sampleCustomProfile)

        // Exactly one durable reservation, synchronously; metadata has not yet
        // half-applied, and the queued cleanup delete has not reached the store —
        // it is enqueued strictly behind the still in-flight save.
        #expect(cleanupStore.markPendingCallCountSnapshot() == 1)
        #expect(cleanupStore.snapshotPendingIDs() == [sampleCustomProfile.id])
        #expect(model.profiles == [.hosted, sampleCustomProfile])
        #expect(model.operationTask == nil)
        #expect(model.operation == .idle)
        #expect(await tokenStore.deleteCallCount == 0)

        // Let the in-flight save actually succeed and durably apply.
        await tokenStore.resumeOldest()
        await staleOperationTask?.value

        // The save durably applied, but the stale auth task's own generation was
        // already invalidated before it ever reached this point, so it must not
        // resurrect a signed-in session for the profile being removed.
        #expect(
            model.sessionState == .signedOut(profile: sampleCustomProfile, compatibility: .legacy)
        )
        #expect(await tokenStore.saveCallCount == 1)

        // Only now — strictly after the save it was queued behind resolved — does
        // the reserved cleanup delete actually reach the store.
        await tokenStore.waitUntilPending(1)
        #expect(
            await tokenStore.pendingMutations() == [.delete(profileID: sampleCustomProfile.id)]
        )
        await tokenStore.resumeOldest()

        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(model.profiles == [.hosted])
        #expect(model.selectedProfile == .hosted)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        // No second mark for the whole flow, and no orphaned token for the removed
        // profile's endpoint left behind in the store.
        #expect(cleanupStore.markPendingCallCountSnapshot() == 1)
        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
        #expect(await tokenStore.snapshotTokens()[sampleCustomProfile.id] == nil)
        #expect(await tokenStore.deleteCallCount == 1)
    }
}
