@testable import ArkhamHorrorShared
import Testing

/// Regression coverage for the credential-cleanup-registry corruption state
/// (`SessionState.credentialCleanupRegistryCorrupted`) and its explicit,
/// user-confirmed recovery (`AppModel.confirmCredentialCleanupRegistryReset()`),
/// distinct from the existing metadata-destructive `.storageCorrupted` reset. See
/// `AppModel+CleanupReservation.swift` (`pendingCleanupRegistryIDs`,
/// `isCredentialCleanupRegistryCorrupted`) and
/// `AppModel+CredentialCleanupRegistryReset.swift`.
extension AppModelTests {
    /// A malformed/non-canonical marker enumeration failure classifies as the
    /// distinct registry-corruption state — never as a per-profile
    /// `.unavailable`/Retry loop, which a plain `retry()` could never actually repair.
    @Test(
        """
        A malformed cleanup-marker enumeration failure transitions to the distinct \
        registry-corruption state, not a per-profile unavailable/retry loop, and \
        plain retry() remains a no-op for it
        """
    )
    func malformedMarkerEnumerationIsDistinctCorruptionState() async {
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        cleanupStore.setPendingReadError(TokenCleanupPendingStoreError.corruptData)
        let failure = await model.resolvePendingCleanup(for: ServerProfile.hosted.id)
        #expect(failure == .other)
        #expect(
            model.sessionState ==
                .credentialCleanupRegistryCorrupted(TokenCleanupPendingStoreError.corruptData)
        )
        #expect(model.isCredentialCleanupRegistryCorrupted)

        // Never surfaced as `.unavailable`/`.incompatible`, so a plain `retry()`
        // (which only ever matches those two cases) is correctly a no-op — the only
        // recovery is the explicit, confirmed reset below.
        model.retry()
        #expect(model.isCredentialCleanupRegistryCorrupted)
    }

    /// Ordinary per-profile cleanup resolution is entirely unaffected while the
    /// registry itself can be read cleanly (i.e. this corruption state truly is
    /// distinct, not a renamed umbrella for every cleanup failure).
    @Test("Ordinary cleanup resolution succeeds normally when the registry is not corrupted")
    func ordinaryCleanupResolutionUnaffectedWhenRegistryHealthy() async {
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        let failure = await model.resolvePendingCleanup(for: ServerProfile.hosted.id)
        #expect(failure == nil)
        #expect(!model.isCredentialCleanupRegistryCorrupted)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }

    /// The full confirmed-reset happy path: a pre-existing in-flight save is fully
    /// drained (the pre-existing FIFO barrier ordering already proven for
    /// `confirmStorageReset()` in `AppModelStorageResetBarrierTests.swift`), then
    /// `deleteAllTokens()` runs, then `clearAll()` runs, profile metadata is
    /// completely untouched throughout, and the flow restarts for the still-selected
    /// profile afterward.
    @Test(
        """
        A confirmed credential-cleanup-registry reset drains in-flight token work, \
        deletes every token, then clears every marker, leaves profile metadata \
        untouched, and restarts the flow
        """
    )
    func confirmedResetSucceedsInOrderAndPreservesProfiles() async {
        let profileStore = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile], selectedID: sampleCustomProfile.id
        )
        let tokenStore = GatedTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: profileStore,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value
        #expect(model.selectedProfile == sampleCustomProfile)

        cleanupStore.setPendingReadError(TokenCleanupPendingStoreError.corruptData)
        _ = await model.resolvePendingCleanup(for: sampleCustomProfile.id)
        #expect(model.isCredentialCleanupRegistryCorrupted)
        cleanupStore.setPendingReadError(nil)

        let log = await confirmResetWhileSaveInFlight(model: model, tokenStore: tokenStore)

        let deleteAllInvokedIndex = log.firstIndex(of: .invoked(.deleteAll))
        #expect(deleteAllInvokedIndex != nil)
        if let saveAppliedIndex = log.firstIndex(
            of: .applied(.save(token: "in-flight-token", profileID: sampleCustomProfile.id))
        ), let deleteAllInvokedIndex {
            #expect(saveAppliedIndex < deleteAllInvokedIndex)
        } else {
            Issue.record("Expected the in-flight save to have applied before delete-all ran")
        }

        #expect(cleanupStore.snapshotPendingIDs().isEmpty)
        #expect(model.profiles == [.hosted, sampleCustomProfile])
        #expect(model.selectedProfile == sampleCustomProfile)
        #expect(!model.isCredentialCleanupRegistryCorrupted)
        #expect(model.profileManagementFailure == nil)
        #expect(model.profileManagementOperation == .idle)
    }

    /// Starts a save for `sampleCustomProfile` already mid-flight, suspended inside
    /// `tokenStore`, confirms the credential-cleanup-registry reset while it is
    /// pending, then fully drains both before returning `tokenStore`'s own
    /// append-only event log — split out purely to keep the calling test within the
    /// function-length lint limit. Deliberately performs no snapshot-based assertion
    /// mid-flight for the same reason `AppModelStorageResetBarrierTests` avoids one:
    /// only the final, fully drained event log can distinguish genuine ordering from
    /// a race the scheduler simply hasn't exposed yet.
    private func confirmResetWhileSaveInFlight(
        model: AppModel, tokenStore: GatedTokenStore
    ) async -> [GatedTokenStoreEvent] {
        let saveTask = Task {
            await model.performAuthOperation(
                profile: sampleCustomProfile, compatibility: .legacy,
                epochContext: CredentialOperationContext(
                    generation: model.generation,
                    credentialEpoch: model.currentCredentialEpoch(for: sampleCustomProfile.id),
                    globalEpoch: model.currentGlobalCredentialEpoch()
                )
            ) { _ in AuthToken(token: "in-flight-token") }
        }
        await tokenStore.waitUntilPending(1)

        model.confirmCredentialCleanupRegistryReset()

        await tokenStore.resumeOldest()
        await saveTask.value
        await tokenStore.waitUntilPending(1)
        await tokenStore.resumeOldest()
        await model.profileManagementTask?.value
        await model.flowTask?.value

        return await tokenStore.eventLog()
    }

    /// A `deleteAllTokens()` failure during the confirmed reset preserves the
    /// registry-corrupted state (never silently drops back to a healthy-looking
    /// state) and never reaches `clearAll()`.
    @Test(
        """
        A deleteAllTokens failure during a confirmed registry reset preserves the \
        corruption state, surfaces a typed failure, and never reaches clearAll
        """
    )
    func deleteAllFailureDuringResetNeverReachesClearAll() async {
        let tokenStore = FakeTokenStore()
        await tokenStore.setDeleteAllError(KeychainError.unhandledStatus(-1))
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        cleanupStore.setPendingReadError(TokenCleanupPendingStoreError.corruptData)
        _ = await model.resolvePendingCleanup(for: ServerProfile.hosted.id)
        #expect(model.isCredentialCleanupRegistryCorrupted)
        cleanupStore.setPendingReadError(nil)
        // Arm a marker so a wrongly-reached `clearAll()` would be observable.
        cleanupStore.setClearError(nil)
        try? cleanupStore.markPending(ServerProfile.hosted.id)

        model.confirmCredentialCleanupRegistryReset()
        await model.profileManagementTask?.value

        #expect(model.isCredentialCleanupRegistryCorrupted)
        #expect(
            model.profileManagementFailure ==
                .tokenStore(.keychain(.unhandledStatus(-1)))
        )
        #expect(model.profileManagementOperation == .idle)
        // `clearAll()` was never reached: the marker this test armed is still present.
        #expect(cleanupStore.snapshotPendingIDs() == [ServerProfile.hosted.id])
    }

    /// A `clearAll()` failure (after `deleteAllTokens()` already succeeded) leaves
    /// the state in the recoverable registry-corrupted state rather than silently
    /// resolving, and a subsequent confirmed reset attempt can still succeed once the
    /// underlying failure is cleared.
    @Test(
        """
        A clearAll failure after a successful deleteAllTokens remains in the \
        recoverable corruption state, and a subsequent reset attempt can still \
        succeed
        """
    )
    func clearAllFailureDuringResetRemainsRecoverable() async {
        let tokenStore = FakeTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        cleanupStore.setPendingReadError(TokenCleanupPendingStoreError.corruptData)
        _ = await model.resolvePendingCleanup(for: ServerProfile.hosted.id)
        #expect(model.isCredentialCleanupRegistryCorrupted)
        cleanupStore.setPendingReadError(nil)
        cleanupStore.setClearError(TokenCleanupPendingStoreError.corruptData)

        model.confirmCredentialCleanupRegistryReset()
        await model.profileManagementTask?.value

        #expect(model.isCredentialCleanupRegistryCorrupted)
        #expect(model.profileManagementFailure == .tokenStore(.other))
        #expect(await tokenStore.deleteAllCallCount == 1)

        // Retrying now, with the underlying clear failure resolved, succeeds.
        cleanupStore.setClearError(nil)
        model.confirmCredentialCleanupRegistryReset()
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(!model.isCredentialCleanupRegistryCorrupted)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(model.profileManagementFailure == nil)
    }
}
