@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Startup: hosted profile seeding, custom profile retention, selection restoration,
/// missing selection fallback, and storage corruption handling.
extension AppModelTests {
    @Test("An empty store seeds and persists the hosted profile exactly once")
    func hostedFirstRun() async {
        let store = FakeServerProfileStore()
        let model = AppModel(
            profileStore: store,
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        #expect(store.snapshotProfiles() == [.hosted])
        #expect(store.saveProfilesCallCount == 1)
        #expect(store.snapshotSelectedID() == ServerProfile.hosted.id)
        #expect(store.saveSelectionCallCount == 1)
        #expect(model.profiles == [.hosted])
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }

    @Test("Existing custom profiles are retained when the hosted profile is seeded")
    func customProfilesRetained() async {
        let store = FakeServerProfileStore(profiles: [sampleCustomProfile])
        let model = AppModel(
            profileStore: store,
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        #expect(store.snapshotProfiles() == [.hosted, sampleCustomProfile])
        #expect(model.profiles == [.hosted, sampleCustomProfile])
        // Hosted is newly selected; the custom profile's own identity is untouched.
        #expect(model.profiles.contains(sampleCustomProfile))
    }

    @Test("A stored selected profile ID restores that profile")
    func selectionRestoration() async {
        let store = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile],
            selectedID: sampleCustomProfile.id
        )
        let model = AppModel(
            profileStore: store,
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        #expect(store.saveProfilesCallCount == 0)
        #expect(store.saveSelectionCallCount == 0)
        let expected = SessionState.signedOut(profile: sampleCustomProfile, compatibility: .legacy)
        #expect(model.sessionState == expected)
    }

    @Test("A missing or unknown selected profile ID falls back to hosted and persists it")
    func missingSelectionFallsBackToHosted() async {
        let store = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile],
            selectedID: UUID()
        )
        let model = AppModel(
            profileStore: store,
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        #expect(store.snapshotSelectedID() == ServerProfile.hosted.id)
        #expect(store.saveSelectionCallCount == 1)
        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }

    @Test("Corrupt profile storage surfaces storageCorrupted rather than erasing data")
    func storageCorruptionSurfaced() async {
        let corruption = ServerProfileStoreError.corruptData(key: "ArkhamHorror.serverProfiles")
        let store = FakeServerProfileStore(loadProfilesError: corruption)
        let model = AppModel(
            profileStore: store,
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        #expect(model.sessionState == .storageCorrupted(.profileStore(corruption)))
    }

    @Test("Corrupt selection alone repairs to hosted without discarding profiles/tokens")
    func selectionOnlyCorruptionSilentlyRepairs() async throws {
        // The profiles list itself decodes fine — only the separately-keyed selection
        // value is corrupt — so this must not be conflated with true profile-list
        // corruption: it should silently fall back to hosted and persist that repaired
        // selection, leaving every existing profile (and its token) untouched.
        let corruption = ServerProfileStoreError.corruptData(
            key: "ArkhamHorror.selectedServerProfileID"
        )
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "kept-token"])
        let store = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile],
            loadSelectionError: corruption
        )
        let model = AppModel(
            profileStore: store,
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
        #expect(store.snapshotSelectedID() == ServerProfile.hosted.id)
        #expect(store.saveSelectionCallCount == 1)
        // The profile list itself was never rewritten, and the custom profile's token
        // was never touched.
        #expect(store.saveProfilesCallCount == 0)
        #expect(model.profiles == [.hosted, sampleCustomProfile])
        #expect(await tokenStore.deleteAllCallCount == 0)
        #expect(try await tokenStore.token(for: sampleCustomProfile.id) == "kept-token")
    }

    @Test(
        """
        A launch task already superseded before it starts running does not persist a \
        repaired hosted selection over whatever a newer, still-current operation may \
        already have selected
        """
    )
    func staleLaunchTaskDoesNotPersistSelectionRepair() async {
        // A corrupt selection value would normally repair by falling back to hosted
        // and persisting that fallback (see `selectionOnlyCorruptionSilentlyRepairs`
        // above) — but only if the launch task is still current. `AppModel.init`
        // returns before `flowTask`'s body has actually started running (it is only
        // scheduled at this point), so bumping `generation` here, synchronously and
        // before any `await`, simulates a newer operation (a profile switch, or a
        // second launch) having already superseded this launch task before it ever
        // began — exactly the race `repairSelectionToHosted(generation:)` guards
        // against.
        let corruption = ServerProfileStoreError.corruptData(
            key: "ArkhamHorror.selectedServerProfileID"
        )
        let store = FakeServerProfileStore(
            profiles: [.hosted, sampleCustomProfile],
            loadSelectionError: corruption
        )
        let model = AppModel(
            profileStore: store,
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        model.generation += 1
        await model.flowTask?.value

        // The stale task must never persist its repair, nor advance `sessionState`/
        // `profiles` at all — it must behave exactly like every other stale-generation
        // guard in this file: as though it had never run.
        #expect(store.saveSelectionCallCount == 0)
        #expect(store.snapshotSelectedID() == nil)
        #expect(store.saveProfilesCallCount == 0)
        #expect(model.sessionState == .launching)
        #expect(model.profiles == [])
    }
}

/// Compatibility outcomes: compatible, legacy fallback, incompatible rejection, probe
/// failure, and probe cancellation.
extension AppModelTests {
    @Test("A compatible outcome with no stored token reaches signedOut(.modern)")
    func compatibleOutcomeReachesSignedOut() async {
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.compatible(capabilities: ["a"]))),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        let expected = SessionState.signedOut(
            profile: .hosted, compatibility: .modern(capabilities: ["a"])
        )
        #expect(model.sessionState == expected)
    }

    @Test("A legacy (HTTP 404) outcome reaches signedOut(.legacy)")
    func legacyOutcomeReachesSignedOut() async {
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        #expect(model.sessionState == .signedOut(profile: .hosted, compatibility: .legacy))
    }

    @Test("An incompatible outcome exposes the exact typed rejection and blocks auth")
    func incompatibleOutcomeBlocksAuth() async {
        let rejection = CompatibilityRejection.serverTooOld(
            serverRevision: .literal(major: 0, minor: 1, patch: 0),
            clientRequires: .literal(major: 0, minor: 1, patch: 11)
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.incompatible(reason: rejection))),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        #expect(model.sessionState == .incompatible(profile: .hosted, reason: rejection))
        #expect(model.sessionState.isRetryable)
    }

    @Test("A probe failure exposes a recoverable unavailable state")
    func probeFailureIsRecoverable() async {
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(
                .failure(CapabilityProbeError.nonHTTPResponse)
            ),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        let expected = SessionState.unavailable(
            profile: .hosted, reason: .probeFailed(.nonHTTPResponse)
        )
        #expect(model.sessionState == expected)
        #expect(model.sessionState.isRetryable)
    }

    @Test("An unexpected probe error cannot retain its description in session state")
    func unexpectedProbeErrorIsSanitized() async {
        let secret = "private-probe-detail"
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(
                .failure(SensitiveTestFailure(description: secret))
            ),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        let diagnostic: String? = switch model.sessionState {
        case let .unavailable(_, .probeFailed(.transportFailure(value))):
            value
        default:
            nil
        }
        #expect(diagnostic == "Unexpected capability probe failure.")
        #expect(diagnostic?.contains(secret) == false)
    }

    @Test("Probe cancellation does not become an error")
    func probeCancellationIsNotAnError() async {
        let model = AppModel(
            profileStore: FakeServerProfileStore(),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.failure(CancellationError())),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        #expect(model.sessionState == .checkingCompatibility(profile: .hosted))
    }
}
