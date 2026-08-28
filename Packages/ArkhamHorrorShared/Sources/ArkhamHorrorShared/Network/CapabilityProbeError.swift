/// Errors produced by ``CapabilityProbe`` for all observable failures.
enum CapabilityProbeError: Error, Sendable {
    /// The response was not an HTTP response.
    ///
    /// Indicates a non-HTTP scheme was used or an unexpected protocol substitution
    /// occurred during testing.
    case nonHTTPResponse
    /// The server returned an unexpected HTTP status code.
    ///
    /// HTTP 404 is handled separately as ``CompatibilityOutcome/legacyFallback``
    /// and is never reported here.
    case unexpectedStatus(Int)
    /// The 2xx response body could not be decoded as a valid ``ServerCapabilities`` payload.
    ///
    /// The associated `String` is a diagnostic message from the decoder and is intended
    /// for logging only; do not rely on its exact content in production logic.
    case malformedPayload(String)
    /// A transport-level failure (network unreachable, DNS failure, TLS error, timeout).
    ///
    /// The associated `String` is a diagnostic description of the underlying error and
    /// is intended for logging only; do not rely on its exact content in production logic.
    case transportFailure(String)
}

extension CapabilityProbeError: Equatable {
    static func == (lhs: CapabilityProbeError, rhs: CapabilityProbeError) -> Bool {
        switch (lhs, rhs) {
        case (.nonHTTPResponse, .nonHTTPResponse):
            true
        case let (.unexpectedStatus(lCode), .unexpectedStatus(rCode)):
            lCode == rCode
        case (.malformedPayload, .malformedPayload):
            // Diagnostic strings are informational only; equality ignores them.
            true
        case (.transportFailure, .transportFailure):
            // Diagnostic strings are informational only; equality ignores them.
            true
        default:
            false
        }
    }
}
