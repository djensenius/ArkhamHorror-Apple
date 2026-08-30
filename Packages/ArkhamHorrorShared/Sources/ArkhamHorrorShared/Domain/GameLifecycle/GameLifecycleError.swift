/// Errors produced by ``GameLifecycleService`` for all observable failures.
///
/// Mirrors ``AuthenticationError``'s shape and non-disclosure guarantees: no case
/// embeds a response body, request header, or token value, and where a diagnostic
/// string is carried it is derived only from a transport-level error (never the
/// response body) and is for logging only -- ``Equatable`` ignores it.
enum GameLifecycleError: Error, Sendable {
    /// The response was not an HTTP response (unexpected protocol or test substitution).
    case nonHTTPResponse
    /// The server returned HTTP 401: the token was absent, invalid, or has since been
    /// revoked. Distinct from ``AuthenticationError/unauthorized`` (a different type
    /// entirely) so a caller cannot accidentally conflate a rejected sign-in attempt
    /// with an authenticated session that has since expired -- the latter must
    /// invalidate any already-loaded game content and route through
    /// `AppModel`'s existing single token authority
    /// (`AppModel.handleGameLifecycleSessionExpired(profile:)`), never silently sign
    /// out or leave stale content on screen.
    case sessionExpired
    /// The server returned an unexpected, non-401 status code.
    ///
    /// The associated value is the numeric status code, which is non-secret. Covers
    /// every legality/validation rejection this client does not itself special-case
    /// (404 unknown game, 400 invalid seat/investigator, 403 seat already
    /// taken/not a multiplayer game, 500 engine failure): this client never
    /// synthesizes those backend rules itself, so it cannot distinguish them beyond
    /// their status code without guessing at an undocumented response-body shape.
    case unexpectedStatus(Int)
    /// A 2xx response body could not be decoded into the expected typed payload.
    case malformedPayload
    /// The request body could not be JSON-encoded through ``ContractJSON``.
    case requestEncodingFailed
    /// The current session token could not be securely accessed (a ``TokenStore``
    /// failure distinct from the server explicitly rejecting it -- see
    /// ``sessionExpired``).
    case tokenUnavailable
    /// The requested path segment could not be safely represented in a URL (defense
    /// in depth; every typed identifier this client sends is already validated and
    /// percent-encodes cleanly, so this should be unreachable in production).
    case invalidPathSegment
    /// A transport-level failure (network unreachable, DNS failure, TLS error, timeout).
    ///
    /// The associated `String` is a diagnostic description of the underlying transport
    /// error and is intended for logging only; it never contains request headers or
    /// the response body. Do not rely on its exact content in production logic.
    case transportFailure(String)
}

extension GameLifecycleError: Equatable {
    static func == (lhs: GameLifecycleError, rhs: GameLifecycleError) -> Bool {
        switch (lhs, rhs) {
        case (.nonHTTPResponse, .nonHTTPResponse),
             (.sessionExpired, .sessionExpired),
             (.malformedPayload, .malformedPayload),
             (.requestEncodingFailed, .requestEncodingFailed),
             (.tokenUnavailable, .tokenUnavailable),
             (.invalidPathSegment, .invalidPathSegment):
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
