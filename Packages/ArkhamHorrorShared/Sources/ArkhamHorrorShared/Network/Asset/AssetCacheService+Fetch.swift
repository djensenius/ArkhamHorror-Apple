import CoreGraphics
import Foundation

/// The network-fetch-and-validate pipeline for a normal (non-revalidation)
/// cache miss, plus the two small helpers it shares with
/// `AssetCacheService+Revalidation.swift`. Split out of the main actor file
/// purely to stay under this package's file-length limit; every member
/// here is still actor-isolated `AssetCacheService` state/behavior.
extension AssetCacheService {
    /// Walks `candidates` in order against the network, advancing only on
    /// an exact 404, validating and persisting the first successful
    /// response. Re-checks cancellation *and* `token` immediately before
    /// publishing so a last-waiter cancellation, or a concurrent
    /// authoritative mutation (an `evictAll()`, or a more-recently-issued
    /// operation for the same key), racing with a just-completed network
    /// read, never results in a published, now-stale entry.
    func fetchAndValidate(
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate],
        token: CacheToken
    ) async throws -> CachedAsset {
        // `token` arrives already fully stamped (both
        // ``CacheToken/durableClearEpoch`` and
        // ``CacheToken/diskWriteGeneration``) by
        // ``coalescedFetch(key:cacheKey:candidates:)``'s own synchronous
        // issuance, from a snapshot ``beginIssuance(for:)`` captured
        // *before* that call site's atomic "check the coalescing
        // dictionary, else create and insert" section even began — never
        // restamped here, after this function's own suspension past that
        // point (see ``beginIssuance(for:)``'s doc comment for why).
        for candidate in candidates {
            try Task.checkCancellation()
            let url = candidate.url(base: key.source)
            let result = try await transport.fetch(AssetHTTPRequest(url: url), limits: limits)
            switch result {
            case .notFound:
                continue
            case .notModified:
                // An unconditional request never carries `If-None-Match` or
                // `If-Modified-Since`, so a 304 here indicates a
                // non-conforming server; there is no cached payload to pair
                // it with.
                throw AssetError.staleConditionalResponse
            case let .success(response):
                return try await validateAndPublish(
                    candidate: candidate,
                    url: url,
                    cacheKey: cacheKey,
                    token: token,
                    response: response
                )
            }
        }
        throw AssetError.candidatesExhausted
    }

    /// Validates and publishes a single successful network response for
    /// `fetchAndValidate`'s current candidate, factored out purely to keep
    /// that function's own body within this package's length convention.
    private func validateAndPublish(
        candidate: AssetCandidate,
        url: URL,
        cacheKey: AssetCacheKey,
        token: CacheToken,
        response: AssetHTTPResponse
    ) async throws -> CachedAsset {
        let validated = try AssetImageValidator.validate(
            data: response.body,
            declaredContentType: response.contentType,
            expectedFormat: candidate.format,
            limits: limits
        )
        try Task.checkCancellation()
        // See the identical decode gate in ``assembleRevalidatedAsset`` for
        // why a full platform decode — not just the pure metadata/dimension
        // parse above — is required before publication. Offloaded via
        // ``decodeImageOffActor`` so this CPU-bound decode never blocks
        // unrelated cache requests on this actor.
        let decoded = try await decodeImageOffActor(response.body)
        guard decoded.width == validated.width, decoded.height == validated.height else {
            throw AssetError.malformedImageData
        }
        try Task.checkCancellation()
        guard await isAuthoritative(token, for: cacheKey) else {
            throw AssetError.staleOperation
        }
        // `token.durableClearEpoch`/`diskAuthorityID` are `nil` only
        // if this token's own durable epoch read/disk issuance failed
        // at issuance time -- a case `isAuthoritative(_:for:)` already
        // treats as permanently unacceptable everywhere this asset could
        // ever be published, so this can never currently escape into a
        // live cache entry. But these fields are the sole provenance
        // stamps later revalidations trust to detect cache laundering
        // (see `AssetCacheMetadata`'s own doc comment) -- silently
        // substituting `0` here rather than failing this exact assembly
        // step would weaken that invariant for any future caller that
        // reaches this method with a differently gated token. Fail
        // exactly like the authority check just above would have,
        // rather than publishing an entry with a fabricated stamp; this
        // matches `assembleRevalidatedAsset`'s identical gate.
        guard
            let clearEpochAtPublication = token.durableClearEpoch,
            let authorityIDAtPublication = token.diskAuthorityID
        else {
            throw AssetError.staleOperation
        }
        let asset = CachedAsset(
            payload: response.body,
            metadata: AssetCacheMetadata(
                cacheKeyHex: cacheKey.digestHex,
                contentType: response.contentType ?? validated.format.mimeType,
                encodedByteCount: response.body.count,
                width: validated.width,
                height: validated.height,
                payloadSHA256Hex: Self.sha256Hex(response.body),
                etag: response.etag,
                lastModified: response.lastModified,
                resolvedURLString: url.absoluteString,
                insertedAt: Date(),
                accessSequence: AssetAccessSequence(0),
                clearEpochAtPublication: clearEpochAtPublication,
                authorityIDAtPublication: authorityIDAtPublication
            ),
            durableClearEpoch: token.durableClearEpoch,
            authorityID: token.diskAuthorityID
        )
        try Task.checkCancellation()
        guard await isAuthoritative(token, for: cacheKey) else {
            throw AssetError.staleOperation
        }
        // `publish` performs its own final authority re-check immediately
        // before returning (see ``MutationOutcome``'s doc comment): a
        // `.stale` outcome here means a more-recently-issued operation for
        // this exact key (or `evictAll()`) already superseded this fetch
        // — including one retired by ``retireIfCurrent(_:for:)`` when the
        // last waiter for this exact work cancelled — while `publish`
        // itself was suspended, so this caller must not hand back `asset`
        // as if it were still the resolved, cache-consistent answer for
        // this key.
        guard await publish(cacheKey, asset: asset, token: token) == .applied else {
            throw AssetError.staleOperation
        }
        await testOnlyPauseAfterFetchPublishApplied?()
        return asset
    }

    /// Resolves `key`'s candidate chain, first checking whether `digest`
    /// itself is in a known-broken configuration state. A localization
    /// lookup that failed to load its backing resource answers
    /// ``LocalizedDigestLookup/hasLocalizedArt(_:locale:)`` with `false`
    /// for everything, which — left unchecked — is indistinguishable from
    /// a legitimately non-localized identifier and would silently resolve
    /// to the English candidate, masking a packaging/configuration
    /// regression as ordinary fallback behavior. Checked here, ahead of
    /// every caller (``asset(for:)`` and ``revalidate(for:)`` alike), so
    /// neither path can reach that silent substitution.
    func resolvedCandidates(for key: AssetKey) throws -> [AssetCandidate] {
        if let configurationError = digest.configurationError {
            throw configurationError
        }
        let candidates = AssetLocator.candidates(for: key, digest: digest)
        guard !candidates.isEmpty else { throw AssetError.candidatesExhausted }
        return candidates
    }

    /// Decodes `payload` on a genuine structured child task rather than
    /// synchronously on this actor's own executor, so a full platform
    /// image decode — whose CPU cost is not accounted for or bounded by
    /// ``AssetCacheLimits`` — never blocks unrelated cache
    /// requests/coalescing/cancellation handling for however long that
    /// decode takes.
    ///
    /// `async let` starts a real child task that inherits this call's
    /// cancellation (unlike a detached task), and the child task itself
    /// checks cancellation before ever calling
    /// ``AssetImageDecoder/decode(_:)``: if the caller was already
    /// cancelled at that point, this throws `CancellationError` without
    /// spending any CPU on a decode nobody wants. `decode(_:)` itself is
    /// synchronous with no cooperative cancellation check while it runs,
    /// so a cancellation strictly *during* an already-started decode does
    /// not interrupt it — decoding still runs to completion. Beyond that
    /// single up-front check, this method's benefit is that the decode's
    /// CPU cost runs off the actor's own executor. Not `private`: shared
    /// by every call site across `AssetCacheService+Revalidation.swift`
    /// too.
    func decodeImageOffActor(_ payload: Data) async throws -> CGImage {
        async let decodedImage: CGImage = {
            try Task.checkCancellation()
            return try AssetImageDecoder.decode(payload)
        }()
        return try await decodedImage
    }

    static func sha256Hex(_ data: Data) -> String {
        AssetPayloadHasher.sha256Hex(data)
    }
}
