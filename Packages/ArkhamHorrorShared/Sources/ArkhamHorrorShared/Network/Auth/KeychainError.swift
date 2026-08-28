import Foundation

/// A non-secret error surfaced by ``KeychainTokenStore``.
///
/// No case carries token contents, account labels, or any other secret. `OSStatus`
/// values are opaque numeric status codes and are safe to log.
enum KeychainError: Error, Equatable, Sendable {
    /// A token consisting only of whitespace (or empty) was rejected before storage.
    ///
    /// Such a token can never authenticate a request, so it is never persisted.
    case emptyToken
    /// A stored item was returned but its bytes were not valid UTF-8 token data.
    ///
    /// Indicates external corruption of the keychain item; the raw bytes are **not**
    /// included here.
    case unexpectedData
    /// The Security framework returned a status that the store does not handle.
    ///
    /// `errSecItemNotFound` is handled distinctly by the store (absent token / no-op
    /// delete) and is never reported through this case. The associated value is the raw
    /// `OSStatus`, which is non-secret.
    case unhandledStatus(OSStatus)
}
