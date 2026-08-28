import Foundation

/// An async abstraction over per-server API token storage.
///
/// Tokens are keyed by a stable ``ServerProfile/id`` (`UUID`) so that hosted and custom
/// servers never share a credential. The production conformance is
/// ``KeychainTokenStore``; there is intentionally no insecure fallback.
///
/// An empty or whitespace-only stored token is never treated as a valid credential:
/// ``token(for:)`` returns `nil` for such a value, and ``save(_:for:)`` rejects it.
protocol TokenStore: Sendable {
    /// Returns the stored token for `profileID`, or `nil` when none is stored (or the
    /// stored value is empty/whitespace-only).
    func token(for profileID: UUID) async throws -> String?
    /// Stores `token` for `profileID`, replacing any existing value.
    ///
    /// - Throws: an error if `token` is empty/whitespace-only or if storage fails.
    func save(_ token: String, for profileID: UUID) async throws
    /// Removes any stored token for `profileID`. Removing an absent token is not an error.
    func deleteToken(for profileID: UUID) async throws
}
