/// Details submitted to the public `POST /register` endpoint.
///
/// Mirrors the backend contract's `Registration` schema exactly: the request body
/// carries `email`, `username`, and `password`. No client-side validation rules beyond
/// the contract are imposed here; the server is the authority on registration validity.
///
/// This value contains a secret (`password`) and is never logged, persisted, or embedded
/// in error diagnostics.
struct RegistrationDetails: Codable, Equatable, Sendable {
    /// The account email address.
    let email: String
    /// The desired account username.
    let username: String
    /// The chosen password. Secret; never logged or persisted.
    let password: String
}
