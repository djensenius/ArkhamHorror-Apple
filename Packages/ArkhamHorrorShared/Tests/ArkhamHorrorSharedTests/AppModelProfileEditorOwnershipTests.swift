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
}
