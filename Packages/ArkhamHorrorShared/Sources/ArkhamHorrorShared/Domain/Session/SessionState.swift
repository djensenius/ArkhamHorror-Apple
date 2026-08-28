/// The kind of authentication operation currently in flight, if any.
///
/// Tracked separately from ``SessionState`` so presentation code can show progress
/// (e.g. disable a sign-in button) without the operation itself being able to mutate
/// the session's launch/authentication state until it durably succeeds.
enum SessionOperation: Equatable, Sendable {
    case idle
    case signingIn
    case registering
    case signingOut
}

/// A ``TokenStore`` failure, surfaced distinctly from authentication failures.
///
/// The production ``TokenStore`` conformance (``KeychainTokenStore``) always throws
/// ``KeychainError``; that case preserves the exact typed rejection. ``other`` is a
/// defensive fallback for a non-production conformance that throws a different error
/// type; it never carries any diagnostic content, so no accidental secret or arbitrary
/// data can leak through it.
enum TokenStoreFailure: Equatable, Sendable {
    case keychain(KeychainError)
    case other
}

/// Why a restored token could not be validated, distinguishing transient failures
/// (which retain the token) from storage failures.
enum TokenValidationFailure: Equatable, Sendable {
    /// `whoami` failed for a reason other than HTTP 401 (network, TLS, status, or
    /// decoding). The stored token is retained.
    case authentication(AuthenticationError)
    /// Reading or deleting the stored token itself failed.
    case tokenStore(TokenStoreFailure)
}

/// Why the selected server is currently unavailable. Recoverable via `AppModel.retry()`.
enum SessionUnavailableReason: Equatable, Sendable {
    /// The capability probe could not complete.
    case probeFailed(CapabilityProbeError)
    /// Restoring the selected profile's token failed.
    case tokenValidationFailed(TokenValidationFailure)
}

/// Why loading or saving persisted profile/selection storage failed.
enum SessionStorageFailure: Equatable, Sendable {
    /// The exact typed rejection from ``ServerProfileStore``.
    case profileStore(ServerProfileStoreError)
    /// A non-production store conformance threw an error of an unexpected type.
    case unexpected
}

/// A transient failure from an in-flight sign-in, registration, or sign-out operation.
///
/// Kept separate from ``SessionState`` so a failed operation never falsely changes the
/// session's launch/authentication state (for example, a sign-out whose token deletion
/// fails must leave the session signed in).
enum SessionOperationFailure: Equatable, Sendable {
    case authentication(AuthenticationError)
    case tokenStore(TokenStoreFailure)
}

extension SessionOperationFailure {
    /// A short, user-facing, non-secret summary of this failure.
    var message: String {
        switch self {
        case .authentication(.unauthorized):
            "Authentication was rejected. Check your details and try again."
        case .authentication:
            "Could not complete authentication. Try again."
        case .tokenStore:
            "Could not securely access your session. Try again."
        }
    }
}

/// The compatibility posture of a server that has already passed the capability probe.
///
/// Both cases permit sign-in and authentication restoration to proceed; ``legacy``
/// is the conservative outcome for a pre-contract server (HTTP 404 from the
/// capabilities endpoint) and assumes no modern capability.
enum ServerCompatibility: Equatable, Sendable {
    /// The server declared a contract-compatible capability set.
    case modern(capabilities: Set<String>)
    /// The server pre-dates the capability contract; treated conservatively.
    case legacy
}

/// The top-level, non-secret snapshot of the app's server and authentication session.
///
/// Every case is ``Equatable`` and free of passwords or tokens; ``signedIn`` carries a
/// typed ``CurrentUser`` rather than the bearer token that authenticated it. Transient
/// in-flight operation progress and failures (sign-in, registration, sign-out) are
/// tracked separately by ``AppModel`` so a failed sign-out or Keychain error never
/// falsely reports this state as signed out.
enum SessionState: Equatable, Sendable {
    /// Persisted profiles and the selected profile are being loaded, or reloaded after
    /// a profile switch.
    case launching
    /// The selected profile's capabilities are being probed.
    case checkingCompatibility(profile: ServerProfile)
    /// The selected server is usable (modern-compatible or legacy) and no authenticated
    /// session is currently active.
    case signedOut(profile: ServerProfile, compatibility: ServerCompatibility)
    /// The selected server rejected this client build as incompatible.
    case incompatible(profile: ServerProfile, reason: CompatibilityRejection)
    /// The selected server could not be reached, or its response could not be
    /// processed. Recoverable via ``AppModel/retry()``.
    case unavailable(profile: ServerProfile, reason: SessionUnavailableReason)
    /// A restored or newly issued token was validated and durably saved; ``user`` is the
    /// authenticated account.
    case signedIn(profile: ServerProfile, compatibility: ServerCompatibility, user: CurrentUser)
    /// Persisted profile or selection storage is corrupt.
    ///
    /// Exposed rather than silently erased; recovery is intentionally out of scope for
    /// this coordinator.
    case storageCorrupted(SessionStorageFailure)
}

// MARK: - User-facing summaries

/// Non-secret, human-readable summaries used by presentation code.
///
/// No case here ever surfaces a token, password, or raw transport diagnostic; only the
/// typed failure categories already exposed by ``SessionState`` inform the text.
extension SessionState {
    /// A short, user-facing title for the current state.
    var title: String {
        switch self {
        case .launching:
            "Loading"
        case .checkingCompatibility:
            "Checking server"
        case let .signedOut(_, compatibility):
            compatibility == .legacy ? "Server ready (legacy)" : "Server ready"
        case .incompatible:
            "Server incompatible"
        case .unavailable:
            "Server unavailable"
        case let .signedIn(_, _, user):
            "Signed in as \(user.username)"
        case .storageCorrupted:
            "Storage error"
        }
    }

    /// A short, user-facing detail string for the current state.
    var detail: String {
        switch self {
        case .launching:
            "Loading saved servers."
        case let .checkingCompatibility(profile):
            "Checking \(profile.displayName)."
        case let .signedOut(profile, _):
            "\(profile.displayName) is ready."
        case let .incompatible(profile, _):
            "\(profile.displayName) is not compatible with this app version."
        case let .unavailable(profile, reason):
            switch reason {
            case .probeFailed:
                "Could not reach \(profile.displayName). Try again."
            case .tokenValidationFailed(.authentication):
                "Could not verify your session with \(profile.displayName). Try again."
            case .tokenValidationFailed(.tokenStore):
                "Could not securely access your session for \(profile.displayName). Try again."
            }
        case let .signedIn(profile, _, _):
            "Connected to \(profile.displayName)."
        case .storageCorrupted:
            "Saved server data could not be read."
        }
    }

    /// Whether ``AppModel/retry()`` currently applies to this state.
    var isRetryable: Bool {
        switch self {
        case .unavailable, .incompatible:
            true
        default:
            false
        }
    }
}
