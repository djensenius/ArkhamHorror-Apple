@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Regression coverage proving `AppModel/enterCredentialCleanupRegistryCorrupted(_:)`
/// — the single synchronous choke point every credential-cleanup-registry
/// enumeration/noncanonical-marker failure now transitions through (see
/// `AppModel+CleanupReservation.swift`) — can never be silently overwritten by
/// in-flight launch/auth/profile-management work that captured its generation/epoch
/// *before* corruption was discovered, and that no credential material is ever
/// deleted before the explicit, user-confirmed recovery
/// (`AppModel/confirmCredentialCleanupRegistryReset()`) actually runs.
extension AppModelTests {
    /// A cold launch whose very first durable-tombstone enumeration (triggered by
    /// `reconcileUnselectedPendingCleanupTombstones(selectedProfileID:)`, synchronously
    /// inside `loadProfilesAndSelect(generation:)`) fails outright transitions
    /// straight to the corrupted registry state — and, critically, the very next line
    /// in `loadProfilesAndSelect` (an unconditional `sessionState =
    /// .checkingCompatibility(...)` before this fix) no longer overwrites it: the
    /// capability probe is never reached at all.
    @Test(
        """
        A cold launch whose durable-tombstone enumeration fails immediately settles \
        into the registry-corrupted state without ever overwriting it with \
        .checkingCompatibility, and the capability probe is never invoked
        """
    )
    func coldLaunchEnumerationFailureNeverOverwrittenByCheckingCompatibility() async {
        let profileStore = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile], selectedID: sampleCustomProfile.id
        )
        let cleanupStore = FakeTokenCleanupPendingStore()
        cleanupStore.setPendingReadError(TokenCleanupPendingStoreError.corruptData)
        let capabilityProbe = ScriptedCapabilityProbe(.outcome(.legacyFallback))
        let model = AppModel(
            profileStore: profileStore,
            tokenStore: FakeTokenStore(),
            capabilityProbe: capabilityProbe,
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        #expect(
            model.sessionState ==
                .credentialCleanupRegistryCorrupted(TokenCleanupPendingStoreError.corruptData)
        )
        #expect(await capabilityProbe.callCount == 0)
        // The profiles/selection load themselves succeeded before the failing
        // enumeration call, and remain correctly reflected even though corrupted.
        #expect(model.profiles == [.hosted, sampleCustomProfile])
        #expect(model.selectedProfile == sampleCustomProfile)
        #expect(model.operation == .idle)
        #expect(model.profileManagementOperation == .idle)
    }

    /// An in-flight sign-in whose `currentUser` (whoami) call is still suspended when
    /// the registry is independently discovered corrupted cannot, once resumed,
    /// overwrite that corruption with `.signedIn` — its own `isCurrent(generation)`
    /// recheck immediately after `currentUser` resolves fails, since corruption entry
    /// already advanced `generation`.
    @Test(
        """
        An in-flight sign-in suspended at whoami when the registry is discovered \
        corrupted cannot overwrite corruption with .signedIn once resumed
        """
    )
    func activeAuthBeforeWhoamiCannotOverwriteCorruption() async {
        let auth = GatedAuthenticating()
        let tokenStore = FakeTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "raced-token") }
        await auth.waitUntilPending(1)
        let generationBeforeCorruption = model.generation
        let staleOperationTask = model.operationTask

        let entered = model.enterCredentialCleanupRegistryCorrupted(.corruptData)
        #expect(entered)
        #expect(model.generation == generationBeforeCorruption + 1)
        #expect(model.operation == .idle)
        #expect(model.operationTask == nil)
        #expect(model.currentAuthAttemptID == nil)
        #expect(
            model.sessionState ==
                .credentialCleanupRegistryCorrupted(TokenCleanupPendingStoreError.corruptData)
        )

        await auth.resumeOldest(with: .success(.sample))
        await staleOperationTask?.value

        #expect(
            model.sessionState ==
                .credentialCleanupRegistryCorrupted(TokenCleanupPendingStoreError.corruptData)
        )
        #expect(await tokenStore.snapshotTokens().isEmpty)
    }

    /// A sign-in save already admitted into the token store (past its epoch recheck)
    /// when the registry is discovered corrupted may still durably apply — no
    /// in-process mechanism can retroactively stop a mutation the token store has
    /// already been asked to perform — but corruption entry's `generation` bump still
    /// prevents that success from ever being reflected as `.signedIn`, and the
    /// explicit, subsequently confirmed recovery's unconditional `deleteAllTokens()`
    /// still removes the orphaned token: nothing is left behind once recovery
    /// completes.
    @Test(
        """
        A save already admitted into the token store when corruption is discovered \
        cannot surface as .signedIn, and confirmed recovery still removes the \
        orphaned token it durably applied
        """
    )
    func saveAlreadyDispatchedCannotSurfaceSignedInAndRecoveryRemovesOrphan() async throws {
        let tokenStore = GatedTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "raced-token") }
        // Once visible here, the save has already passed its epoch recheck inside
        // `serializedTokenAccess(for:epoch:globalEpoch:_:)`.
        await tokenStore.waitUntilPending(1)
        let staleOperationTask = model.operationTask

        model.enterCredentialCleanupRegistryCorrupted(.corruptData)
        #expect(model.sessionState == .credentialCleanupRegistryCorrupted(.corruptData))
        #expect(await tokenStore.deleteAllCallCount == 0)

        await tokenStore.resumeOldest()
        await staleOperationTask?.value

        // The save durably applied (nothing could have stopped it once admitted), but
        // `generation` no longer matches, so the final `sessionState = .signedIn(...)`
        // write is skipped entirely.
        #expect(try await tokenStore.token(for: ServerProfile.hosted.id) == "raced-token")
        #expect(model.sessionState == .credentialCleanupRegistryCorrupted(.corruptData))

        // No credential material is deleted before explicit confirmation...
        #expect(await tokenStore.deleteAllCallCount == 0)

        // ...but the confirmed recovery's unconditional deleteAllTokens() still
        // removes the orphaned token once the user confirms. `GatedTokenStore` gates
        // `deleteAllTokens()` exactly like `save`/`deleteToken`, so this must be
        // resumed too before the recovery's own task can complete.
        model.confirmCredentialCleanupRegistryReset()
        await tokenStore.waitUntilPending(1)
        #expect(await tokenStore.pendingMutations() == [.deleteAll])
        await tokenStore.resumeOldest()
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(await tokenStore.deleteAllCallCount == 1)
        #expect(await tokenStore.snapshotTokens().isEmpty)
        #expect(!model.isCredentialCleanupRegistryCorrupted)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }

    /// Removing a non-selected custom profile whose token delete is already admitted
    /// into the token store when the registry is discovered corrupted cannot commit
    /// the metadata removal once that delete resolves: `profileManagementGeneration`
    /// no longer matches, so the profile is preserved exactly as it was.
    @Test(
        """
        A non-selected profile removal whose token delete is already admitted when \
        corruption is discovered cannot commit metadata removal once resumed
        """
    )
    func profileRemovalInFlightCannotCommitAfterCorruption() async throws {
        let profileStore = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile], selectedID: ServerProfile.hosted.id
        )
        let tokenStore = GatedTokenStore(tokens: [sampleCustomProfile.id: "old-token"])
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: profileStore,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        model.removeCustomProfile(sampleCustomProfile)
        await tokenStore.waitUntilPending(1)
        let generationBeforeCorruption = model.profileManagementGeneration
        let staleProfileManagementTask = model.profileManagementTask

        let entered = model.enterCredentialCleanupRegistryCorrupted(.corruptData)
        #expect(entered)
        #expect(model.profileManagementGeneration == generationBeforeCorruption + 1)
        #expect(model.profileManagementOperation == .idle)
        #expect(model.profileManagementTask == nil)

        await tokenStore.resumeOldest()
        await staleProfileManagementTask?.value

        // Metadata removal never committed: the profile is preserved exactly as it
        // was, even though the token delete itself durably applied.
        #expect(model.profiles == [.hosted, sampleCustomProfile])
        #expect(try await tokenStore.token(for: sampleCustomProfile.id) == nil)
        #expect(model.sessionState == .credentialCleanupRegistryCorrupted(.corruptData))
        #expect(model.profileManagementFailure == nil)
    }

    /// Every entry point that can start new credential-touching work rejects/no-ops
    /// while the registry-corrupted state is current, rather than treating corruption
    /// entry's reset of `operation`/`profileManagementOperation` back to `.idle` as
    /// "ready for a fresh operation."
    @Test("Every credential-touching entry point rejects while the registry is corrupted")
    func everyEntryPointRejectsWhileCorrupted() async {
        let profileStore = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile], selectedID: ServerProfile.hosted.id
        )
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: profileStore,
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        model.enterCredentialCleanupRegistryCorrupted(.corruptData)
        let profilesBeforeAttempts = model.profiles
        let generationBeforeAttempts = model.generation
        let pmGenerationBeforeAttempts = model.profileManagementGeneration

        #expect(model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "t") } == nil)
        model.selectProfile(sampleCustomProfile)
        model.addCustomProfile(displayName: "New", rawURL: "https://new.example.com")
        #expect(
            model.updateCustomProfile(
                sampleCustomProfile,
                displayName: "Renamed",
                rawURL: sampleCustomProfile.baseURL.absoluteString
            ) == nil
        )
        model.removeCustomProfile(sampleCustomProfile)
        model.retry()

        #expect(model.profiles == profilesBeforeAttempts)
        #expect(model.selectedProfile == .hosted)
        #expect(model.generation == generationBeforeAttempts)
        #expect(model.profileManagementGeneration == pmGenerationBeforeAttempts)
        #expect(model.operation == .idle)
        #expect(model.profileManagementOperation == .idle)
        #expect(model.profileManagementFailure == nil)
        #expect(
            model.sessionState ==
                .credentialCleanupRegistryCorrupted(TokenCleanupPendingStoreError.corruptData)
        )
    }

    /// A second, concurrent registry-enumeration failure discovered by an unrelated
    /// caller while already corrupted is idempotent: it must not re-bump every
    /// generation/epoch a second time, which would gratuitously invalidate a
    /// legitimate operation that only began after the first entry already completed.
    @Test("Entering the corrupted registry state a second time while already corrupted is a no-op")
    func enteringCorruptionTwiceIsIdempotent() async {
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(currentUserResult: .success(.sample)),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        #expect(model.enterCredentialCleanupRegistryCorrupted(.corruptData))
        let generationAfterFirstEntry = model.generation
        let pmGenerationAfterFirstEntry = model.profileManagementGeneration

        #expect(!model.enterCredentialCleanupRegistryCorrupted(.unhandledStatus(-1)))
        #expect(model.generation == generationAfterFirstEntry)
        #expect(model.profileManagementGeneration == pmGenerationAfterFirstEntry)
        // The originally recorded failure is preserved, not replaced by the second,
        // redundant call's failure.
        #expect(model.sessionState == .credentialCleanupRegistryCorrupted(.corruptData))
    }

    /// A stale sign-in interrupted by corruption entry cannot resurrect a session even
    /// after a subsequent confirmed recovery has already installed a fresh
    /// generation: the stale operation's captured generation can never equal *either*
    /// the corruption-entry generation or the later, further-advanced
    /// recovery-restart generation.
    @Test(
        """
        A stale sign-in's late whoami resolution cannot resurrect a session even \
        after a subsequent confirmed recovery has already restarted the flow under a \
        fresh generation
        """
    )
    func staleAuthCannotResurrectSessionAfterSubsequentConfirmedRecovery() async {
        let auth = GatedAuthenticating()
        let tokenStore = FakeTokenStore()
        let cleanupStore = FakeTokenCleanupPendingStore()
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: auth,
            cleanupPendingStore: cleanupStore
        )
        await model.flowTask?.value

        model.beginAuthOperation(.signingIn) { _ in AuthToken(token: "stale-raced-token") }
        await auth.waitUntilPending(1)
        let staleOperationTask = model.operationTask

        model.enterCredentialCleanupRegistryCorrupted(.corruptData)
        model.confirmCredentialCleanupRegistryReset()
        await model.profileManagementTask?.value
        await model.flowTask?.value

        #expect(!model.isCredentialCleanupRegistryCorrupted)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))

        // The stale sign-in's whoami call, still suspended from before corruption was
        // ever entered, resolves only now — strictly after recovery has already
        // restarted the flow under its own, further-advanced generation.
        await auth.resumeOldest(with: .success(.sample))
        await staleOperationTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(await tokenStore.snapshotTokens().isEmpty)
    }
}
