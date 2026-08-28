/// Errors produced when validating a ``ServerProfile`` base URL or display name.
enum ServerProfileError: Error, Equatable, Sendable {
    /// The input was empty or contained only whitespace.
    case emptyURL
    /// The display name was empty or contained only whitespace.
    case emptyDisplayName
    /// The supplied UUID is reserved for the canonical hosted profile.
    ///
    /// Custom profiles must use a different UUID. The hosted profile's UUID is
    /// deterministic and must not be reused by user-created profiles.
    case reservedID
    /// Embedded credentials (`user@host` or `user:pass@host`) are not permitted.
    ///
    /// Credentials are never stored in a server profile; use the authentication
    /// slice to supply tokens separately.
    case credentialsNotAllowed
    /// Only `http` and `https` schemes are supported.
    case unsupportedScheme
    /// A non-empty host is required.
    case missingHost
    /// Fragment components (`#…`) are not permitted in server base URLs.
    case fragmentNotAllowed
    /// Query strings (`?…`) are not permitted in server base URLs.
    case queryNotAllowed
    /// The URL contains the API path segment sequence `/api/v1`.
    ///
    /// Supply the server root URL without the API path; the client appends
    /// the prefix automatically when constructing endpoint URLs.
    case apiPrefixAlreadyPresent
    /// The URL string could not be parsed.
    case malformedURL
}
