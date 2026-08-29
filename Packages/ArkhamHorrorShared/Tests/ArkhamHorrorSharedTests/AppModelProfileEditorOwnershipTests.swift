@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic multiwindow coverage for server-profile editor ownership:
/// `AppModel` is shared process-wide across every window (see `AppModel.swift`'s own
/// documentation), so two windows can each have a `ServerProfileEditorView` open for
/// the very same custom profile at once. `ServerProfileEditorView` only treats a
/// `.saving(profileID) -> .idle` transition as *its own* completed save when the
/// submission identity `AppModel.updateCustomProfile(_:displayName:rawURL:)` returned
/// to it (remembered locally as `ownedSubmissionID`) still matches
/// `AppModel.currentProfileSubmissionID` — matching the profile ID alone is not
/// enough, since a second, entirely different editor for the same profile produces an
/// identical `.saving(profileID) -> .idle` transition. These tests exercise the
/// underlying `AppModel` invariant that guard depends on directly, since only one
/// `updateCustomProfile` save can ever be in flight at a time (see its `.idle` guard):
/// a submitting editor's own captured ID must match `currentProfileSubmissionID`
/// exactly when (and only when) its own save is the one that just completed.
extension AppModelTests {
    private func makeEditorOwnershipModel(
        tokenStore: any TokenStore = FakeTokenStore()
    ) -> AppModel {
        AppModel(
            profileStore: FakeServerProfileStore(profiles: [.hosted, sampleCustomProfile]),
            tokenStore: tokenStore,
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
    }

    @Test(
        """
        A non-submitting editor's stale/absent submission ID does not match another \
        editor's completed save for the same profile, so it would not spuriously \
        dismiss and lose its own unsaved fields; it can still submit and dismiss on \
        its own ID afterward
        """
    )
    func nonSubmittingEditorDoesNotMatchAnotherEditorsCompletion() async throws {
        let model = makeEditorOwnershipModel()
        await model.flowTask?.value

        // Editor B opens the same profile for editing but never itself submits —
        // exactly like `ServerProfileEditorView`'s freshly initialized
        // `ownedSubmissionID`, which starts `nil`.
        let ownedByEditorB: UUID? = nil

        // Editor A (a second, independent window) submits a rename of the very same
        // profile and remembers its own submission identity, exactly as
        // `ServerProfileEditorView.submit()` captures `updateCustomProfile(...)`'s
        // return value.
        let submissionA = model.updateCustomProfile(
            sampleCustomProfile, displayName: "A's Rename", rawURL: sampleCustomProfile
                .baseURL.absoluteString
        )
        try #require(submissionA != nil)
        await model.profileManagementTask?.value

        #expect(model.profileManagementFailure == nil)
        #expect(model.profileManagementOperation == .idle)
        #expect(model.currentProfileSubmissionID == submissionA)
        #expect(model.profiles.first { $0.id == sampleCustomProfile.id }?.displayName ==
            "A's Rename")

        // The exact guard `ServerProfileEditorView.onChange` relies on: editor B's
        // remembered (absent) submission ID must not equal the identity of the save
        // that just completed, so B would not treat A's completion as its own.
        #expect(ownedByEditorB != model.currentProfileSubmissionID)

        // Editor B, having correctly stayed open, now submits its own edit and
        // should recognize *that* completion as its own.
        let editedByB = try #require(model.profiles.first { $0.id == sampleCustomProfile.id })
        let submissionB = model.updateCustomProfile(
            editedByB, displayName: "B's Rename", rawURL: editedByB.baseURL.absoluteString
        )
        try #require(submissionB != nil)
        try #require(submissionB != submissionA)
        await model.profileManagementTask?.value

        #expect(model.profileManagementFailure == nil)
        #expect(model.currentProfileSubmissionID == submissionB)
        // Now B's own remembered submission ID matches — this is the transition B's
        // editor should (and, in `ServerProfileEditorView`, does) dismiss on.
        #expect(submissionB == model.currentProfileSubmissionID)
        #expect(model.profiles.first { $0.id == sampleCustomProfile.id }?.displayName ==
            "B's Rename")
    }

    @Test(
        """
        A stale submission ID from a completed edit of one profile does not match a \
        later edit's completion for a different profile
        """
    )
    func staleSubmissionForOneProfileDoesNotMatchAnotherProfilesCompletion() async throws {
        let otherProfile = try ServerProfile.custom(
            displayName: "Other Self-Host", rawURL: "https://other.example.com"
        )
        let model = AppModel(
            profileStore: FakeServerProfileStore(
                profiles: [.hosted, sampleCustomProfile, otherProfile]
            ),
            tokenStore: FakeTokenStore(),
            capabilityProbe: ScriptedCapabilityProbe(.outcome(.legacyFallback)),
            authenticationSession: ScriptedAuthenticating(),
            cleanupPendingStore: FakeTokenCleanupPendingStore()
        )
        await model.flowTask?.value

        // An editor window for `sampleCustomProfile` submits and completes, capturing
        // its own submission identity.
        let submissionForSampleProfile = model.updateCustomProfile(
            sampleCustomProfile,
            displayName: "Renamed Sample",
            rawURL: sampleCustomProfile.baseURL.absoluteString
        )
        try #require(submissionForSampleProfile != nil)
        await model.profileManagementTask?.value
        #expect(model.profileManagementFailure == nil)

        // A second, unrelated editor window for a completely different profile now
        // submits its own edit.
        let submissionForOtherProfile = model.updateCustomProfile(
            otherProfile, displayName: "Renamed Other", rawURL: otherProfile.baseURL.absoluteString
        )
        try #require(submissionForOtherProfile != nil)
        try #require(submissionForOtherProfile != submissionForSampleProfile)
        await model.profileManagementTask?.value
        #expect(model.profileManagementFailure == nil)
        #expect(model.currentProfileSubmissionID == submissionForOtherProfile)

        // The first editor's stale, already-resolved submission ID must not match
        // this later, unrelated completion.
        #expect(submissionForSampleProfile != model.currentProfileSubmissionID)
    }

    // MARK: - Optimistic concurrency: stale opening snapshot

    @Test(
        """
        A second editor's immutable opening snapshot is rejected as a conflict — \
        without mutating the live profile, deleting any token, or touching state — \
        once a first editor has already changed that same profile's endpoint; the \
        second editor's own input is never overwritten with stale data
        """
    )
    func staleOpeningSnapshotEndpointEditIsRejectedWithoutMutatingLiveProfile() async throws {
        let tokenStore = FakeTokenStore(tokens: [sampleCustomProfile.id: "old-token"])
        let model = makeEditorOwnershipModel(tokenStore: tokenStore)
        await model.flowTask?.value

        // Both editor A and editor B open on the very same immutable snapshot.
        let openingSnapshotForBothEditors = sampleCustomProfile

        // Editor A commits an endpoint change and fully completes before editor B
        // ever submits — no operation is in flight when B calls in, so B's rejection
        // can only come from the snapshot mismatch itself, never the `.idle` guard.
        let submissionA = model.updateCustomProfile(
            openingSnapshotForBothEditors,
            displayName: "A's Server",
            rawURL: "https://a-changed-host.example.com"
        )
        try #require(submissionA != nil)
        await model.profileManagementTask?.value
        #expect(model.profileManagementFailure == nil)
        let afterA = try #require(model.profiles.first { $0.id == sampleCustomProfile.id })
        #expect(afterA.displayName == "A's Server")
        #expect(afterA.baseURL.host == "a-changed-host.example.com")
        let deleteCallCountAfterA = await tokenStore.deleteCallCount

        // Editor B never re-fetched: it still holds the exact snapshot it opened
        // with, from before A's edit, and submits its own (different) change to it.
        let submissionB = model.updateCustomProfile(
            openingSnapshotForBothEditors,
            displayName: "B's Server",
            rawURL: "https://b-changed-host.example.com"
        )

        // Rejected synchronously: no submission identity, no operation started.
        #expect(submissionB == nil)
        #expect(model.profileManagementFailure == .editConflict)
        #expect(model.profileManagementOperation == .idle)

        // A's already-committed change is completely undisturbed by B's stale
        // submission: not overwritten with B's (older) name/host, and no additional
        // token-store activity was ever triggered by the rejected attempt.
        let stillCurrent = try #require(model.profiles.first { $0.id == sampleCustomProfile.id })
        #expect(stillCurrent == afterA)
        #expect(stillCurrent.displayName == "A's Server")
        #expect(stillCurrent.baseURL.host == "a-changed-host.example.com")
        #expect(await tokenStore.deleteCallCount == deleteCallCountAfterA)
    }

    @Test(
        """
        A second editor's stale opening snapshot is rejected as a conflict even when \
        the first editor's own edit only changed the display name, not the endpoint
        """
    )
    func staleOpeningSnapshotNameOnlyEditIsRejectedWithoutMutatingLiveProfile() async throws {
        let model = makeEditorOwnershipModel()
        await model.flowTask?.value
        let openingSnapshotForBothEditors = sampleCustomProfile

        let submissionA = model.updateCustomProfile(
            openingSnapshotForBothEditors,
            displayName: "Renamed By A",
            rawURL: sampleCustomProfile.baseURL.absoluteString
        )
        try #require(submissionA != nil)
        await model.profileManagementTask?.value
        #expect(model.profileManagementFailure == nil)

        // Editor B still holds the pre-rename snapshot and submits its own edit
        // without ever having observed A's rename.
        let submissionB = model.updateCustomProfile(
            openingSnapshotForBothEditors,
            displayName: "Renamed By B",
            rawURL: sampleCustomProfile.baseURL.absoluteString
        )

        #expect(submissionB == nil)
        #expect(model.profileManagementFailure == .editConflict)
        #expect(model.profiles.first { $0.id == sampleCustomProfile.id }?.displayName ==
            "Renamed By A")
    }

    @Test(
        """
        The commit-boundary recheck immediately before persisting an endpoint-changing \
        edit rejects a profile that changed underneath it during the cleanup \
        suspension, rather than persisting the submitting editor's now-stale update \
        over whatever changed it
        """
    )
    func commitBoundaryRecheckRejectsProfileMutatedDuringCleanupSuspension() async throws {
        // A gated store lets this test hold the edit's own cleanup delete pending so
        // a mutation can be injected during the real `await` suspension inside
        // `performProfileUpdate`, proving the recheck immediately before the write —
        // not merely the synchronous check in `updateCustomProfile` — is what
        // actually protects the write, exactly as its doc comment describes.
        let tokenStore = GatedTokenStore(tokens: [sampleCustomProfile.id: "old-token"])
        let model = makeEditorOwnershipModel(tokenStore: tokenStore)
        await model.flowTask?.value

        let submission = model.updateCustomProfile(
            sampleCustomProfile,
            displayName: "Submitted Edit",
            rawURL: "https://submitted-host.example.com"
        )
        try #require(submission != nil)
        await tokenStore.waitUntilPending(1)

        // Simulate a profile mutation landing during the suspension — something the
        // process-wide `profileManagementOperation` serialization guard makes
        // unreachable today, but which this recheck must still guard against on its
        // own, independent of that invariant holding.
        let mutatedElsewhere = try ServerProfile.custom(
            id: sampleCustomProfile.id,
            displayName: "Changed During Suspension",
            rawURL: "https://changed-during-suspension.example.com"
        )
        model.profiles = model.profiles.map {
            $0.id == sampleCustomProfile.id ? mutatedElsewhere : $0
        }

        await tokenStore.resumeOldest()
        await model.profileManagementTask?.value

        #expect(model.profileManagementFailure == .editConflict)
        // The injected mutation is exactly what remains — the submitting edit never
        // persisted over it.
        #expect(model.profiles.first { $0.id == sampleCustomProfile.id } == mutatedElsewhere)
    }
}
