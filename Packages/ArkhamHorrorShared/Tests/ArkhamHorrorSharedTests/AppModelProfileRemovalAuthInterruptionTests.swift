@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for the single-reservation auth-interruption transaction used by
/// ``AppModel/removeCustomProfile(_:)``/``AppModel/updateCustomProfile(_:displayName:rawURL:)``
/// when the profile being mutated is also the one with an active in-flight
/// sign-in/registration: ``AppModel/reserveCleanupInterruptingActiveAuth(for:)``.
///
/// Before this transaction existed, removing the *selected* profile only reserved
/// token cleanup and bumped its credential epoch; the stale auth operation's
/// generation/task/state were left untouched, and the subsequent hosted fallback went
/// through the *public* `selectProfile(_:)`, which issued its own **second**,
/// independently fallible `markPending` reservation for the same profile *after*
/// metadata had already been persisted as removed. `activateHostedProfileAfterRemoval()`
/// now performs that fallback without any further reservation, so this file proves: a
/// single mark covers the whole removal, a stuck auth operation for the removed
/// profile is coherently reset in the same transaction as the reservation, and an
/// initial mark failure leaves everything — including any in-flight auth
/// operation — completely untouched.
extension AppModelTests {
    @Test(
        """
        Removing the selected profile with an active auth operation resets it in \
        the same transaction
        """
    )
    func removingSelectedProfileWithActiveAuthResetsOperation() async {
        // A slow whoami validation stands in for any in-flight sign-in at the moment
        // the removal lands, exactly as
        // `endpointChangeOfSelectedProfileResetsInFlightAuthOperation` does for edits.
        let auth = GatedAuthenticating()
        let tokenStore = FakeTokenStore()
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [.hosted, sampleCustomProfile], selectedID: sampleCustomProfile.id
            ),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value
        #expect(
            model.sessionState == .signedOut(profile: sampleCustomProfile, compatibility: .legacy)
        )

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        #expect(model.operation == .signingIn)

        // Captured before removal (which resets `operationTask` to `nil` in the same
        // transaction as the reservation) so this test can deterministically await the
        // stale operation's own completion below.
        let staleOperation = model.operationTask

        model.removeCustomProfile(sampleCustomProfile)
        await model.profileManagementTask?.value
        await model.flowTask?.value

        // The removal's single reservation also reset the stuck auth operation exactly
        // as `cancelAuthOperation()`/`selectProfile(_:)` already do, so sign-in/register
        // UI for the fallback hosted profile is not left permanently disabled.
        #expect(model.operation == .idle)
        #expect(model.operationFailure == nil)
        #expect(model.operationTask == nil)
        #expect(model.profiles == [.hosted])
        #expect(model.selectedProfile == .hosted)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        // The abandoned whoami now resolves successfully, out of order, well after the
        // removal; it must not resurrect a session or save a token for the
        // already-removed profile.
        await auth.resumeOldest(with: .success(.sample))
        await staleOperation?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(await tokenStore.saveCallCount == 0)
    }

    @Test(
        """
        A markPending failure while removing the selected profile with an active \
        auth operation preserves the operation, its task, generation, and the \
        profile list exactly
        """
    )
    func removingSelectedProfileMarkFailurePreservesActiveAuthOperationExactly() async throws {
        let auth = GatedAuthenticating()
        let tokenStore = FakeTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [.hosted, sampleCustomProfile], selectedID: sampleCustomProfile.id
            ),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        #expect(model.operation == .signingIn)
        let generationBeforeRemoval = model.generation
        let profilesBeforeRemoval = model.profiles

        cleanupStore.setMarkError(TokenCleanupPendingStoreError.corruptData)
        model.removeCustomProfile(sampleCustomProfile)
        await model.profileManagementTask?.value

        // The reservation itself could not be made durable: nothing about the active
        // auth operation, its generation, or the profile list is touched.
        #expect(model.operation == .signingIn)
        #expect(model.generation == generationBeforeRemoval)
        #expect(model.profiles == profilesBeforeRemoval)
        guard case .tokenStore = model.profileManagementFailure else {
            Issue.record(
                """
                Expected .tokenStore failure, got \
                \(String(describing: model.profileManagementFailure))
                """
            )
            return
        }

        // The still-genuinely-active operation completes normally once its own whoami
        // resolves, proving it was never orphaned by the failed removal attempt.
        await auth.resumeOldest(with: .success(.sample))
        await model.operationTask?.value

        #expect(
            model.sessionState ==
                .signedIn(profile: sampleCustomProfile, compatibility: .legacy, user: .sample)
        )
        #expect(try await tokenStore.token(for: sampleCustomProfile.id) == "issued-token")
    }

    @Test(
        """
        Removing the selected profile issues exactly one markPending \
        reservation, never a second
        """
    )
    func removingSelectedProfileDoesNotIssueSecondMarkPending() async {
        // No token is preloaded for the selected profile: `GatedAuthenticating`'s
        // `currentUser` never resolves on its own, so a preloaded token would make
        // the model's own launch-time token restoration hang on the very first
        // `whoami` call, before this test ever reaches its own `beginAuthOperation`.
        let auth = GatedAuthenticating()
        let tokenStore = FakeTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [.hosted, sampleCustomProfile], selectedID: sampleCustomProfile.id
            ),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)

        model.removeCustomProfile(sampleCustomProfile)
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(model.profiles == [.hosted])
        #expect(model.selectedProfile == .hosted)
        // The whole removal — including its hosted-fallback activation — issued a
        // single `markPending` reservation: `activateHostedProfileAfterRemoval()`
        // does not re-invoke the public, independently fallible
        // `interruptActiveAuthOperationIfNeeded()` path a second time.
        #expect(cleanupStore.markPendingCallCountSnapshot() == 1)

        // Let the abandoned whoami resolve so the model has no dangling continuation.
        await auth.resumeOldest(with: .success(.sample))
    }

    @Test(
        """
        Arming a failure for a hypothetical second markPending call does not \
        surface it, because removing the selected profile never issues one
        """
    )
    func removingSelectedProfileSecondMarkFailureInjectionNeverSurfaces() async {
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "token"])
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [.hosted, sampleCustomProfile], selectedID: sampleCustomProfile.id
            ),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        // Armed to fail starting at the second call; if removal ever issued a second,
        // independent reservation (the pre-fix bug), this would surface as a typed
        // failure instead of a clean removal.
        cleanupStore.setMarkError(TokenCleanupPendingStoreError.corruptData, fromCallCount: 2)

        model.removeCustomProfile(sampleCustomProfile)
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(model.profileManagementFailure == nil)
        #expect(model.profiles == [.hosted])
        #expect(model.selectedProfile == .hosted)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(cleanupStore.markPendingCallCountSnapshot() == 1)
    }

    @Test(
        """
        A markPending failure while editing the selected profile's endpoint with an \
        active auth operation preserves the operation, its task, and the profile \
        list exactly
        """
    )
    func updateCustomProfileMarkFailureWithActiveAuthPreservesOperationAndProfile() async throws {
        let auth = GatedAuthenticating()
        let tokenStore = FakeTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [.hosted, sampleCustomProfile], selectedID: sampleCustomProfile.id
            ),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        model.beginAuthOperation(.registering) { _ in AuthToken(token: "issued-token") }
        await auth.waitUntilPending(1)
        #expect(model.operation == .registering)
        let generationBeforeEdit = model.generation
        let profilesBeforeEdit = model.profiles

        cleanupStore.setMarkError(TokenCleanupPendingStoreError.corruptData)
        model.updateCustomProfile(
            sampleCustomProfile,
            displayName: sampleCustomProfile.displayName,
            rawURL: "https://new-host.example.com"
        )
        await model.profileManagementTask?.value

        #expect(model.operation == .registering)
        #expect(model.generation == generationBeforeEdit)
        #expect(model.profiles == profilesBeforeEdit)
        guard case .tokenStore = model.profileManagementFailure else {
            Issue.record(
                """
                Expected .tokenStore failure, got \
                \(String(describing: model.profileManagementFailure))
                """
            )
            return
        }

        await auth.resumeOldest(with: .success(.sample))
        await model.operationTask?.value

        #expect(
            model.sessionState ==
                .signedIn(profile: sampleCustomProfile, compatibility: .legacy, user: .sample)
        )
        #expect(try await tokenStore.token(for: sampleCustomProfile.id) == "issued-token")
    }
}
