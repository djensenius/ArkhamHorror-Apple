/// The authenticated account returned by `GET /whoami`.
///
/// Mirrors the backend contract's `CurrentUser` schema exactly: `username`, `email`,
/// `beta`, and `admin` are all required. Decoding fails if any field is missing or has
/// the wrong type, giving strict typed decoding of the documented contract.
struct CurrentUser: Codable, Equatable, Sendable {
    /// The account username.
    let username: String
    /// The account email address.
    let email: String
    /// Whether the account has opted into beta features.
    let beta: Bool
    /// Whether the account has administrator privileges.
    let admin: Bool
}
