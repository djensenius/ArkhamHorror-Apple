import Foundation

/// A typed, `SessionState`-derived presentation route for the account/server UI.
///
/// Pure and `Equatable`: constructing one from a `SessionState` and its `profiles`
/// requires no SwiftUI, networking, or persistence, so the state-to-route mapping
/// itself is deterministically testable without any view-inspection dependency.
/// Every view in `Presentation/` is a direct,
/// side-effect-free rendering of one `AccountRoute` case.
enum AccountRoute: Equatable, Sendable {
    /// Persisted profiles are loading, or the selected profile's capabilities are being
    /// probed and its token restored. `profileName` is set only once a profile has been
    /// resolved (``SessionState/checkingCompatibility(profile:)``).
    case launch(profileName: String?)
    /// The selected server is usable and no authenticated session is active.
    case serverSelection(
        profiles: [ServerProfile], selected: ServerProfile, compatibility: ServerCompatibility
    )
    /// The selected server rejected this client build.
    case incompatible(profile: ServerProfile, reason: CompatibilityRejection)
    /// The selected server could not be reached or validated; retryable.
    case unavailable(profile: ServerProfile, reason: SessionUnavailableReason)
    /// Persisted profile or selection storage is corrupt; recovery requires explicit
    /// user confirmation.
    case storageCorrupted(SessionStorageFailure)
    /// A validated session is active for the typed current user.
    case account(profile: ServerProfile, compatibility: ServerCompatibility, user: CurrentUser)
}

extension AccountRoute {
    /// Derives the route to present for `sessionState`, given the full saved profile
    /// list (needed only by ``serverSelection(profiles:selected:compatibility:)`` to
    /// offer every saved server, not just the selected one).
    init(sessionState: SessionState, profiles: [ServerProfile]) {
        switch sessionState {
        case .launching:
            self = .launch(profileName: nil)
        case let .checkingCompatibility(profile):
            self = .launch(profileName: profile.displayName)
        case let .signedOut(profile, compatibility):
            self = .serverSelection(
                profiles: profiles, selected: profile, compatibility: compatibility
            )
        case let .incompatible(profile, reason):
            self = .incompatible(profile: profile, reason: reason)
        case let .unavailable(profile, reason):
            self = .unavailable(profile: profile, reason: reason)
        case let .signedIn(profile, compatibility, user):
            self = .account(profile: profile, compatibility: compatibility, user: user)
        case let .storageCorrupted(failure):
            self = .storageCorrupted(failure)
        }
    }
}

/// Stable accessibility identifiers for key actions and fields, shared between views and
/// their deterministic tests so identifier-to-route/action mapping can be verified
/// without a view-inspection dependency.
enum AccountAccessibilityID {
    static let retryButton = "account.retry"
    static let signInEntryButton = "account.signInEntry"
    static let registerEntryButton = "account.registerEntry"
    static let manageServersButton = "account.manageServers"
    static let signInSubmitButton = "account.signIn.submit"
    static let registerSubmitButton = "account.register.submit"
    static let emailField = "account.field.email"
    static let usernameField = "account.field.username"
    static let passwordField = "account.field.password"
    static let signOutButton = "account.signOut"
    static let switchServerButton = "account.switchServer"
    static let addServerButton = "account.addServer"
    static let serverDisplayNameField = "account.server.displayName"
    static let serverURLField = "account.server.url"
    static let serverEditorSaveButton = "account.server.save"
    static let storageResetConfirmButton = "account.storageReset.confirm"
    static let storageResetEntryButton = "account.storageReset.entry"
    static let chooseServerButton = "account.chooseServer"
    static let serverRemoveConfirmButton = "account.server.removeConfirm"
    static let operationFailureText = "account.operationFailure"
    static let profileManagementFailureText = "account.profileManagementFailure"

    /// A per-profile pending-cleanup-failure text identifier, distinct for every
    /// profile that currently has one (see ``AppModel/pendingCleanupFailures``).
    static func pendingCleanupFailureText(for profileID: UUID) -> String {
        "account.pendingCleanupFailure.\(profileID.uuidString)"
    }

    /// A per-profile pending-cleanup retry-action identifier, distinct for every
    /// profile that currently has a pending cleanup failure.
    static func pendingCleanupRetryButton(for profileID: UUID) -> String {
        "account.pendingCleanupRetry.\(profileID.uuidString)"
    }

    /// A per-profile removal-action identifier, distinct for every custom server row.
    ///
    /// A single shared identifier here would make UI automation unable to distinguish
    /// which row's Remove control it tapped (context menu and swipe action both expose
    /// this identifier for every custom profile), so this is keyed by `profileID`.
    static func serverRemoveButton(for profileID: UUID) -> String {
        "account.server.remove.\(profileID.uuidString)"
    }
}
