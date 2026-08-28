@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic tests of the pure `SessionState` → `AccountRoute` mapping. No SwiftUI,
/// networking, or persistence is involved: every `SessionState` case is covered exactly
/// once, matching the acceptance criterion that every coordinator state has an explicit,
/// non-overlapping presentation.
@Suite("AccountRoute")
struct AccountRouteTests {
    private func makeCustomProfile() throws -> ServerProfile {
        try ServerProfile.custom(displayName: "Home Server", rawURL: "https://home.example.com/api")
    }

    @Test("Launching maps to the launch route with no profile name yet")
    func launchingMapsToLaunchRoute() {
        let route = AccountRoute(sessionState: .launching, profiles: [.hosted])
        #expect(route == .launch(profileName: nil))
    }

    @Test("Checking compatibility maps to the launch route naming the profile")
    func checkingCompatibilityMapsToLaunchRoute() {
        let route = AccountRoute(
            sessionState: .checkingCompatibility(profile: .hosted), profiles: [.hosted]
        )
        #expect(route == .launch(profileName: ServerProfile.hosted.displayName))
    }

    @Test("Signed out maps to server selection carrying the full profile list")
    func signedOutMapsToServerSelection() throws {
        let profiles = try [ServerProfile.hosted, makeCustomProfile()]
        let route = AccountRoute(
            sessionState: .signedOut(profile: .hosted, compatibility: .legacy), profiles: profiles
        )
        #expect(
            route == .serverSelection(profiles: profiles, selected: .hosted, compatibility: .legacy)
        )
    }

    @Test("Incompatible maps to the incompatible route with the exact typed reason")
    func incompatibleMapsToIncompatibleRoute() {
        let reason = CompatibilityRejection.serverTooOld(
            serverRevision: .literal(major: 0, minor: 1, patch: 0),
            clientRequires: .literal(major: 0, minor: 1, patch: 11)
        )
        let route = AccountRoute(
            sessionState: .incompatible(profile: .hosted, reason: reason), profiles: [.hosted]
        )
        #expect(route == .incompatible(profile: .hosted, reason: reason))
    }

    @Test("Unavailable maps to the unavailable route with the exact typed reason")
    func unavailableMapsToUnavailableRoute() {
        let reason = SessionUnavailableReason.probeFailed(.nonHTTPResponse)
        let route = AccountRoute(
            sessionState: .unavailable(profile: .hosted, reason: reason), profiles: [.hosted]
        )
        #expect(route == .unavailable(profile: .hosted, reason: reason))
    }

    @Test("Signed in maps to the account route with the typed current user")
    func signedInMapsToAccountRoute() {
        let route = AccountRoute(
            sessionState: .signedIn(profile: .hosted, compatibility: .legacy, user: .previewSample),
            profiles: [.hosted]
        )
        #expect(route == .account(profile: .hosted, compatibility: .legacy, user: .previewSample))
    }

    @Test("Storage corrupted maps to the storage-corrupted route with the exact typed failure")
    func storageCorruptedMapsToStorageCorruptedRoute() {
        let failure = SessionStorageFailure.profileStore(.corruptData(key: "profiles"))
        let route = AccountRoute(sessionState: .storageCorrupted(failure), profiles: [])
        #expect(route == .storageCorrupted(failure))
    }

    @Test("Accessibility identifiers are stable, non-empty, and unique")
    func accessibilityIdentifiersAreStableAndUnique() {
        let identifiers = [
            AccountAccessibilityID.retryButton,
            AccountAccessibilityID.signInEntryButton,
            AccountAccessibilityID.registerEntryButton,
            AccountAccessibilityID.manageServersButton,
            AccountAccessibilityID.signInSubmitButton,
            AccountAccessibilityID.registerSubmitButton,
            AccountAccessibilityID.emailField,
            AccountAccessibilityID.usernameField,
            AccountAccessibilityID.passwordField,
            AccountAccessibilityID.signOutButton,
            AccountAccessibilityID.switchServerButton,
            AccountAccessibilityID.addServerButton,
            AccountAccessibilityID.serverDisplayNameField,
            AccountAccessibilityID.serverURLField,
            AccountAccessibilityID.serverEditorSaveButton,
            AccountAccessibilityID.serverRemoveButton,
            AccountAccessibilityID.storageResetConfirmButton,
        ]
        #expect(identifiers.allSatisfy { !$0.isEmpty })
        #expect(Set(identifiers).count == identifiers.count)
    }
}
