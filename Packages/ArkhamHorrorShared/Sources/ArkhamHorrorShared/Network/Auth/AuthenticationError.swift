/// Errors produced by ``AuthenticationSession`` for all observable failures.
///
/// No case embeds a response body, request header, password, or token value. Where a
/// diagnostic string is carried it is derived only from a transport-level error (which
/// never contains request headers or the response body) and is intended for logging
/// only. ``Equatable`` ignores those diagnostic strings.
enum AuthenticationError: Error, Sendable {
    /// The response was not an HTTP response (unexpected protocol or test substitution).
    case nonHTTPResponse
    /// The server returned HTTP 401: the credentials or token were absent or invalid.
    case unauthorized
    /// The server returned an unexpected, non-401 status code.
    ///
    /// The associated value is the numeric status code, which is non-secret.
    case unexpectedStatus(Int)
    /// A 2xx response body could not be decoded into the expected typed payload.
    ///
    /// No decoder detail is carried: an authentication or registration success body
    /// contains a token, so nothing derived from the body is surfaced.
    case malformedPayload
    /// The request body could not be JSON-encoded.
    ///
    /// No detail is carried because the body may contain a password.
    case requestEncodingFailed
    /// A transport-level failure (network unreachable, DNS failure, TLS error, timeout).
    ///
    /// The associated `String` is a diagnostic description of the underlying transport
    /// error and is intended for logging only; it never contains request headers or the
    /// response body. Do not rely on its exact content in production logic.
    case transportFailure(String)
}

extension AuthenticationError: Equatable {
    static func == (lhs: AuthenticationError, rhs: AuthenticationError) -> Bool {
        switch (lhs, rhs) {
        case (.nonHTTPResponse, .nonHTTPResponse),
             (.unauthorized, .unauthorized),
             (.malformedPayload, .malformedPayload),
             (.requestEncodingFailed, .requestEncodingFailed):
            true
        case let (.unexpectedStatus(lCode), .unexpectedStatus(rCode)):
            lCode == rCode
        case (.transportFailure, .transportFailure):
            // Diagnostic strings are informational only; equality ignores them.
            true
        default:
            false
        }
    }
}
