/// Errors produced by ``GameLifecycleService`` for all observable failures.
///
/// Mirrors ``AuthenticationError``'s shape and non-disclosure guarantees for generic
/// failures: no case embeds a request header or token value, and where a diagnostic
/// string is carried it is derived only from a transport-level error and is for logging
/// only -- ``Equatable`` ignores it. Endpoint-specific lifecycle rejections preserve the
/// backend's user-facing Yesod `message` (and the deck endpoint's existing `errorMsg`)
/// so lobby/join/deck validation remains server-owned and visible.
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
    /// failures whose body carries no backend-authored `message`/`errorMsg`, so the UI
    /// falls back to a generic localized description rather than guessing at server
    /// rules it does not own.
    case unexpectedStatus(Int)
    /// A 2xx response body could not be decoded into the expected typed payload.
    case malformedPayload
    /// A join/claim invite mutation succeeded, but the required post-mutation game-list
    /// refresh did not produce a loaded row for that game.
    case inviteRefreshFailed
    /// A lifecycle endpoint returned a user-facing backend rejection.
    case operationFailed(DeckOperationError)
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
             (.inviteRefreshFailed, .inviteRefreshFailed),
             (.requestEncodingFailed, .requestEncodingFailed),
             (.tokenUnavailable, .tokenUnavailable),
             (.invalidPathSegment, .invalidPathSegment):
            true
        case let (.unexpectedStatus(lCode), .unexpectedStatus(rCode)):
            lCode == rCode
        case let (.operationFailed(lError), .operationFailed(rError)):
            lError == rError
        case (.transportFailure, .transportFailure):
            // Diagnostic strings are informational only; equality ignores them.
            true
        default:
            false
        }
    }
}
