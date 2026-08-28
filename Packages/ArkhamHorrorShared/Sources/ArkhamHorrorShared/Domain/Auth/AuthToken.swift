import Foundation

/// The API token returned by `POST /authenticate` and `POST /register`.
///
/// Mirrors the backend contract's `Token` schema: a single `token` string. The token is
/// a bearer secret used as `Authorization: Token <token>` on authenticated requests.
///
/// The token is a secret: it is never logged, and this type's ``Equatable`` and
/// ``Codable`` conformances are the only intended ways to move it. The `token` property
/// is deliberately not surfaced in any human-readable description.
struct AuthToken: Codable, Equatable, Sendable {
    /// The opaque bearer token secret.
    let token: String
}

extension AuthToken {
    /// Whether the token has usable, non-whitespace content.
    ///
    /// The contract does not forbid an empty token string, but an empty or
    /// whitespace-only token can never authenticate a request, so callers treat it as
    /// absent rather than as a valid credential.
    var hasUsableContent: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
