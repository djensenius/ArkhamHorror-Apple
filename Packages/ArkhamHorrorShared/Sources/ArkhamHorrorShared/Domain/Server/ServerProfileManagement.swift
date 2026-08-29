import Foundation

/// The kind of profile add/edit/remove operation currently in flight, if any.
///
/// Tracked separately from ``SessionOperation`` so a custom-server edit or removal
/// cannot be confused with (or interrupt) an in-flight sign-in, registration, or
/// sign-out, and so presentation code can disable server-management controls without
/// touching the authentication UI.
enum ProfileManagementOperation: Equatable, Sendable {
    case idle
    /// A new or edited profile is being validated and persisted.
    case saving(UUID)
    /// A profile (and, first, its token) is being removed.
    case removing(UUID)
    /// Corrupted profile/selection storage is being explicitly, user-confirmed reset:
    /// every stored token is being securely deleted before metadata is replaced.
    case resettingStorage
    /// A corrupted credential-cleanup tombstone registry is being explicitly,
    /// user-confirmed reset: every stored token and every cleanup marker is being
    /// securely deleted, but saved server-profile metadata is left untouched.
    case resettingCredentialCleanupRegistry
}

/// Why an add, edit, or remove of a custom server profile failed.
///
/// No case ever embeds a raw ``Error`` description, a URL fragment derived from
/// arbitrary input beyond what ``ServerProfileError`` already exposes, or any secret.
enum ProfileManagementFailure: Equatable, Sendable {
    /// The supplied display name or URL failed existing ``ServerProfile`` validation.
    case invalidProfile(ServerProfileError)
    /// Another saved profile already resolves to the same normalized endpoint.
    case duplicateEndpoint
    /// The canonical hosted profile cannot be edited or removed.
    case cannotModifyHosted
    /// The profile being edited or removed is no longer in the saved list.
    case profileNotFound
    /// This edit's opening snapshot no longer matches the currently saved profile —
    /// another window already changed it (name and/or endpoint). Nothing was mutated;
    /// the editor should stay open with its unsaved fields so the user can review the
    /// current values and resubmit.
    case editConflict
    /// Securely deleting the profile's token failed; the profile was left unchanged.
    case tokenStore(TokenStoreFailure)
    /// Persisting the updated profile list or selection failed.
    case storage(SessionStorageFailure)
}

extension ServerProfileError {
    /// A short, user-facing, non-secret summary of this validation failure.
    var message: String {
        switch self {
        case .emptyURL:
            "Enter a server address."
        case .emptyDisplayName:
            "Enter a name for this server."
        case .reservedID:
            "That server can't be saved. Try again."
        case .credentialsNotAllowed:
            "Remove the username and password from the address."
        case .unsupportedScheme:
            "Use an address that starts with http:// or https://."
        case .insecureScheme:
            "Use https:// here. Plain http:// only works on loopback (localhost, 127.0.0.0/8, ::1)."
        case .missingHost:
            "Enter a valid server address."
        case .fragmentNotAllowed:
            "Remove the \"#\" portion from the address."
        case .queryNotAllowed:
            "Remove the \"?\" portion from the address."
        case .apiPrefixAlreadyPresent:
            "Don't include the API path; it's added automatically."
        case .malformedURL:
            "Enter a valid server address."
        }
    }
}

extension ProfileManagementFailure {
    /// A short, user-facing, non-secret summary of this failure.
    var message: String {
        switch self {
        case let .invalidProfile(error):
            error.message
        case .duplicateEndpoint:
            "Another saved server already uses that address."
        case .cannotModifyHosted:
            "The hosted server can't be edited or removed."
        case .profileNotFound:
            "That server is no longer available."
        case .editConflict:
            "This server was changed elsewhere. Review the current details and try again."
        case .tokenStore:
            "Could not securely update your saved session for that server. Try again."
        case .storage:
            "Could not save your server changes. Try again."
        }
    }
}
