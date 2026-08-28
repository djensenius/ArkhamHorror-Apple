/// Credentials submitted to the public `POST /authenticate` endpoint.
///
/// Mirrors the backend contract's `Authentication` schema exactly: the request body
/// carries only `email` and `password`. No client-side validation rules beyond the
/// contract are imposed here; the server is the authority on credential validity.
///
/// This value contains a secret (`password`) and is never logged, persisted, or embedded
/// in error diagnostics.
struct AuthenticationCredentials: Codable, Equatable, Sendable {
    /// The account email address.
    let email: String
    /// The account password. Secret; never logged or persisted.
    let password: String
}
