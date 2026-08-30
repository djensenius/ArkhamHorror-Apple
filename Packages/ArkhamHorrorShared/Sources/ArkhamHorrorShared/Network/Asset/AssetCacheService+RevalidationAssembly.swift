import Foundation

/// Assembling a validated, decoded replacement cache entry from a
/// fresh (non-304) revalidation network response, split out of
/// `AssetCacheService+RevalidationCoalescing.swift` purely to keep
/// that file within this package's `file_length` limit.
extension AssetCacheService {
    /// Validates a fresh (non-304) revalidation response and assembles the
    /// replacement cache entry (preserving the original `insertedAt`),
    /// without publishing it — the caller (``performRevalidation``) alone
    /// decides whether this result is still eligible to publish, after
    /// re-checking the generation it was started under.
    ///
    /// Validates against `expectedFormat` — the exact resolved candidate's
    /// format recovered by ``revalidate(for:)`` — rather than
    /// `key.expectedFormat`: candidates for the same key are not all
    /// guaranteed to share one format, so using the key's own default
    /// alone could validate against the wrong magic bytes/MIME
    /// expectations if the candidate chain ever includes mixed formats
    /// (see ``revalidateDiskHit(_:key:cacheKey:candidates:)``, which
    /// recovers it identically for the disk-hit re-validation path).
    func assembleRevalidatedAsset(
        request: RevalidationRequest,
        response: AssetHTTPResponse
    ) async throws -> CachedAsset {
        let validated = try AssetImageValidator.validate(
            data: response.body,
            declaredContentType: response.contentType,
            expectedFormat: request.expectedFormat,
            limits: limits
        )
        try Task.checkCancellation()
        // A full platform decode, not just the pure metadata/dimension
        // parse above, is required before this payload is ever eligible
        // for cache publication: `validate` deliberately only parses
        // enough of a format's structure to safely read declared
        // dimensions without a full decode, so it alone cannot detect an
        // otherwise well-formed header describing a coded image that is
        // truncated, missing, or corrupt (for example a PNG with only an
        // `IHDR` chunk, a JPEG `SOF` with no scan data/EOI, or an AVIF
        // `meta` shell with no backing `mdat`). Cross-checking the
        // decoded image's own dimensions against the validator's parsed
        // dimensions also catches a mismatched/ambiguous primary item.
        let decoded = try await decodeImageOffActor(response.body)
        guard decoded.width == validated.width, decoded.height == validated.height else {
            throw AssetError.malformedImageData
        }
        try Task.checkCancellation()
        return CachedAsset(
            payload: response.body,
            metadata: AssetCacheMetadata(
                cacheKeyHex: request.cacheKey.digestHex,
                contentType: response.contentType ?? validated.format.mimeType,
                encodedByteCount: response.body.count,
                width: validated.width,
                height: validated.height,
                payloadSHA256Hex: Self.sha256Hex(response.body),
                etag: response.etag,
                lastModified: response.lastModified,
                resolvedURLString: request.url.absoluteString,
                insertedAt: request.existing.metadata.insertedAt,
                accessSequence: AssetAccessSequence(0),
                clearEpochAtPublication: request.token.durableClearEpoch ?? 0,
                writeGenerationAtPublication: request.token.diskWriteGeneration ?? 0
            ),
            durableClearEpoch: request.token.durableClearEpoch,
            writeGeneration: request.token.diskWriteGeneration
        )
    }
}
