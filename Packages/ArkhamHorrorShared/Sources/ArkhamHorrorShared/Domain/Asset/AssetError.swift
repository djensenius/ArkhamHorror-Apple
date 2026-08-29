/// Errors produced anywhere in the asset locator, transport, cache, or
/// presentation pipeline.
///
/// This single flat enum spans the whole feature (mirroring the style of
/// ``CapabilityProbeError``) so callers can pattern-match without knowing
/// which internal stage produced the failure. Cases that wrap diagnostic
/// text are for logging only; equality ignores that payload.
enum AssetError: Error, Sendable {
    // MARK: Identifier / URL validation

    /// A category-specific identifier grammar rejected the supplied raw value.
    ///
    /// The associated `String` names the field (e.g. `"cardCode"`) for logging.
    case invalidIdentifier(field: String)
    /// The supplied asset base URL failed strict validation (unsupported
    /// scheme, cleartext on a non-loopback host, credentials, query,
    /// fragment, or an unparseable authority).
    case invalidAssetBase

    // MARK: Candidate resolution

    /// Every candidate in the fallback chain was exhausted (each candidate
    /// either had no digest entry or produced a definitive 404).
    case candidatesExhausted

    // MARK: Transport

    /// The response was not an HTTP response.
    case nonHTTPResponse
    /// The server issued an HTTP redirect (3xx). Every redirect is a failure;
    /// none are followed.
    case redirectRejected(status: Int)
    /// The server returned an unexpected non-2xx, non-404 status code.
    case unexpectedStatus(Int)
    /// The response body exceeded the configured encoded-size cap. Enforced
    /// incrementally while bytes arrive, not after full buffering.
    case responseTooLarge
    /// A genuine transport-level failure (DNS, TLS, timeout, connection reset).
    ///
    /// The associated `String` is diagnostic only.
    case transportFailure(String)
    /// A 304 response arrived but no currently valid cached payload exists to
    /// pair it with.
    case staleConditionalResponse

    // MARK: Content validation

    /// The declared `Content-Type` did not match the expected format.
    case contentTypeMismatch
    /// The body's magic-byte signature did not match the expected format
    /// (or the declared `Content-Type`, once that passed).
    case signatureMismatch
    /// The body was too short or structurally malformed to parse dimensions.
    case malformedImageData
    /// A decoded dimension (width or height) exceeded the configured maximum.
    case dimensionTooLarge
    /// The decoded pixel count (width × height) exceeded the configured
    /// maximum, or the multiplication would have overflowed.
    case pixelCountTooLarge

    // MARK: Cache

    /// The on-disk payload failed integrity validation against its metadata
    /// (size or SHA-256 mismatch) and was quarantined.
    case corruptCacheEntry
    /// Persisting the payload and metadata atomically failed; no half
    /// entry was left on disk.
    case cachePersistenceFailed(String)
}

extension AssetError: Equatable {
    static func == (lhs: AssetError, rhs: AssetError) -> Bool {
        switch (lhs, rhs) {
        case let (.invalidIdentifier(lhsValue), .invalidIdentifier(rhsValue)):
            lhsValue == rhsValue
        case (.invalidAssetBase, .invalidAssetBase),
             (.candidatesExhausted, .candidatesExhausted),
             (.nonHTTPResponse, .nonHTTPResponse),
             (.responseTooLarge, .responseTooLarge),
             (.staleConditionalResponse, .staleConditionalResponse),
             (.contentTypeMismatch, .contentTypeMismatch),
             (.signatureMismatch, .signatureMismatch),
             (.malformedImageData, .malformedImageData),
             (.dimensionTooLarge, .dimensionTooLarge),
             (.pixelCountTooLarge, .pixelCountTooLarge),
             (.corruptCacheEntry, .corruptCacheEntry):
            true
        case let (.redirectRejected(lhsValue), .redirectRejected(rhsValue)):
            lhsValue == rhsValue
        case let (.unexpectedStatus(lhsValue), .unexpectedStatus(rhsValue)):
            lhsValue == rhsValue
        case (.transportFailure, .transportFailure),
             (.cachePersistenceFailed, .cachePersistenceFailed):
            // Diagnostic strings are informational only; equality ignores them.
            true
        default:
            false
        }
    }
}
