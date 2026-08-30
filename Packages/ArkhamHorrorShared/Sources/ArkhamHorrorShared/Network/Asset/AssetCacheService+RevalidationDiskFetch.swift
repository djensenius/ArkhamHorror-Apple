import Foundation

/// ``AssetCacheService/revalidate(for:)``'s disk-hit/fetch-fallback
/// continuation, split into its own file purely to keep
/// `AssetCacheService+Revalidation.swift` within this package's
/// `file_length` convention.
extension AssetCacheService {
    /// The disk-hit/fetch-fallback continuation of ``revalidate(for:)``,
    /// reached only once that method's memory-hit fast path has already
    /// been ruled out. Factored out purely to keep `revalidate(for:)`'s
    /// own body within this package's `function_body_length` convention;
    /// every comment/invariant documented here applies exactly as if
    /// still inlined at that call site.
    func revalidateFromDiskOrFetch(
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate]
    ) async throws -> CachedAsset {
        // Snapshotted *before* the disk read itself (not issued as a
        // token yet) -- see ``snapshotAuthority(for:)``'s doc comment on
        // `asset(for:)`'s identical disk-hit branch for why this must not
        // itself consume an issuance number: a disk miss, or a hit that
        // loses the race checked by ``unchanged(since:for:)``, must never
        // supersede whatever fetch/revalidation is legitimately already in
        // flight for this key. A disk miss and a disk hit whose read lost
        // that race are treated identically: there is no reliable,
        // currently-authoritative cached entry left to revalidate against,
        // so both report the same typed error rather than a stale hit
        // being silently promoted into a conditional request.
        beginAuthorityWindow(for: cacheKey)
        defer { endAuthorityWindow(for: cacheKey) }
        let snapshot = await snapshotAuthority(for: cacheKey)
        guard
            let onDisk = try await diskCache.get(cacheKey),
            await unchanged(since: snapshot, for: cacheKey)
        else {
            throw AssetError.staleConditionalResponse
        }
        // This disk-hit branch is never behind any coalescing dictionary,
        // so there is no "duplicate in-flight work" hazard to defer this
        // past — see ``issueToken(for:)``. Stamped with both halves of
        // this key's durable authority immediately after issuance,
        // exactly like ``asset(for:)``'s identical disk-hit branch — see
        // ``beginIssuance(for:)``'s doc comment.
        let authority = await beginIssuance(for: cacheKey)
        var token = issueToken(for: cacheKey)
        token.durableClearEpoch = authority.clearEpoch
        token.diskWriteGeneration = authority.diskWriteGeneration
        // A disk-loaded body is never trusted as the basis for a
        // conditional request until it has passed the exact same current
        // format/magic-byte/dimension/limits/decode validation as a disk
        // *hit* in ``asset(for:)`` (see
        // ``revalidateDiskHit(_:key:cacheKey:candidates:token:)``):
        // without this, a persisted wrong-format, oversized, undecodable,
        // or stale-limits body could be silently "touched" (its
        // `accessSequence` refreshed) or re-cached in memory the moment
        // the server happens to answer with 304, never re-validated
        // against this process's current contract at all.
        guard let validated = try await revalidateDiskHit(
            onDisk,
            key: key,
            cacheKey: cacheKey,
            candidates: candidates,
            token: token
        ) else {
            // Already quarantined by `revalidateDiskHit`: there is no
            // longer any valid basis for a *conditional* request, so fall
            // through to an ordinary unconditional fetch exactly as if
            // this had been a clean cache miss, rather than throwing or
            // risking a 304 paired with content nobody has validated.
            return try await coalescedFetch(key: key, cacheKey: cacheKey, candidates: candidates)
        }
        // `revalidateDiskHit` suspends (a full platform decode): re-check
        // authority immediately before doing anything further with
        // `validated`. A concurrent, more-recently-issued operation (or
        // `evictAll()`) may already have invalidated or superseded this
        // exact key while the decode above was in flight; if so, restart
        // entirely from a fresh lookup: whatever is now current for this
        // key (freshly published by memory, freshly revalidated from
        // disk, or a brand fresh fetch) is always the correct answer, and
        // never once involves the bytes this now-stale token was derived
        // from.
        guard await isAuthoritative(token, for: cacheKey) else {
            return try await asset(for: key)
        }
        await testOnlyPauseBeforeRevalidationRequest?()
        // Deliberately does *not* insert `validated` into the memory
        // cache here, before any conditional network round trip has even
        // been attempted: doing so previously let a concurrent
        // `evictAll()`/`invalidate()` that completed *after* this
        // insertion landed, but *before* the network step ever accounted
        // for it, still get "crossed" — the network step used to always
        // mint a brand-new token via ``issueToken(for:)`` regardless of
        // `token`'s own fate, and a fresh token is, by construction,
        // always authoritative the instant it is issued, even one issued
        // moments after a clear. That let a 304 for a request built from
        // these exact already-decoded (and, at that point,
        // already-superseded) bytes sail through the terminal authority
        // check in ``performRevalidation(_:)`` and republish content the
        // clear had just removed. `token.durableClearEpoch` — read at the
        // exact same moment this decode was captured and just
        // re-verified under, above — is instead carried straight through
        // to the network step via `preIssuedAuthority:` below (never the
        // token itself: see
        // ``revalidateExisting(_:key:cacheKey:candidates:preIssuedAuthority:)``'s
        // doc comment for why forwarding this branch's own already-issued
        // token would clobber whatever token an already in-flight
        // coalesced revalidation for this key is relying on): if any
        // invalidation supersedes this epoch/generation at *any* point
        // between here and that request's eventual terminal outcome (a
        // 304, a 404, or a fresh 200), ``performRevalidation(_:)``'s own
        // authority check will correctly reject it as stale rather than
        // resurrecting these bytes — see
        // ``resolveRevalidationFetchID(expectedFormat:existing:slot:preIssuedAuthority:)``.
        return try await revalidateExisting(
            validated,
            key: key,
            cacheKey: cacheKey,
            candidates: candidates,
            preIssuedAuthority: PreIssuedAuthority(
                clearEpoch: token.durableClearEpoch,
                diskWriteGeneration: token.diskWriteGeneration
            )
        )
    }
}
