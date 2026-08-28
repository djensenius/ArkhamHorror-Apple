/// A narrow, injectable capability-probing interface used by the session coordinator.
///
/// ``CapabilityProbe`` is the production conformance. Tests inject a deterministic fake
/// so the coordinator's compatibility handling can be exercised without real network I/O.
protocol CapabilityProbing: Sendable {
    /// Probes `profile` and returns its compatibility outcome.
    ///
    /// - Throws: ``CapabilityProbeError`` for observable probe failures; rethrows
    ///   `CancellationError` when the task is cancelled.
    func probe(_ profile: ServerProfile) async throws -> CompatibilityOutcome
}

extension CapabilityProbe: CapabilityProbing {}

/// A narrow, injectable authentication interface used by the session coordinator.
///
/// ``AuthenticationSession`` is the production conformance. Tests inject a deterministic
/// fake so sign-in, registration, and token-validation flows can be exercised without
/// real network I/O.
protocol AppAuthenticating: Sendable {
    /// Exchanges credentials for a token. Never durably persisted by this call alone.
    func authenticate(
        _ credentials: AuthenticationCredentials,
        on profile: ServerProfile
    ) async throws -> AuthToken

    /// Creates an account and returns a token. Never durably persisted by this call alone.
    func register(
        _ details: RegistrationDetails,
        on profile: ServerProfile
    ) async throws -> AuthToken

    /// Validates `token` and returns the authenticated account.
    ///
    /// - Throws: ``AuthenticationError/unauthorized`` when the server explicitly rejects
    ///   the token; another ``AuthenticationError`` for transient failures.
    func currentUser(on profile: ServerProfile, token: String) async throws -> CurrentUser
}

extension AuthenticationSession: AppAuthenticating {}
