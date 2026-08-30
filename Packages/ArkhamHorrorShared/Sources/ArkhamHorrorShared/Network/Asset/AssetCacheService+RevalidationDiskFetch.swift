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
        // **Deliberately reserves no durable per-key disk authority, and
        // issues no local token, here.** See
        // ``AssetCacheService/diskHitIfTrusted(key:cacheKey:candidates:)``'s
        // doc comment for the full reasoning: an intermediate revision of
        // this exact fix called ``issueToken(for:)`` purely to have
        // something to compare this function's own post-decode fail-fast
        // re-check against below — but that unconditionally overwrites
        // ``AssetCacheService/keyLatestToken`` for `cacheKey`, which can
        // durably clobber whatever token an already in-flight coalesced
        // revalidation for this exact key currently depends on, wrongly
        // rejecting its own eventual, perfectly legitimate publish/touch
        // as stale the instant a second, ultimately-joining caller also
        // happens to reach this same code path. `snapshot` above is
        // reused for that re-check instead: a plain, read-only capture
        // with no side effects at all, answering the identical question
        // ("has anything more authoritative for this key become current
        // since I started?") without ever writing to `keyLatestToken`.
        // Fresh per-key reservation (when one turns out to be needed at
        // all) is deferred entirely to
        // ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:preIssuedAuthority:)``'s
        // own join-or-create decision below, which derives it fresh from
        // `onDisk`'s own historical stamp only on the "create" branch --
        // so a joiner truly reserves/issues nothing, anywhere.
        // A disk-loaded body is never trusted as the basis for a
        // conditional request until it has passed the exact same current
        // format/magic-byte/dimension/limits/decode validation as a disk
        // *hit* in ``asset(for:)`` (see
        // ``revalidateDiskHit(_:key:cacheKey:candidates:)``):
        // without this, a persisted wrong-format, oversized, undecodable,
        // or stale-limits body could be silently "touched" (its
        // `accessSequence` refreshed) or re-cached in memory the moment
        // the server happens to answer with 304, never re-validated
        // against this process's current contract at all.
        guard let validated = try await revalidateDiskHit(
            onDisk,
            key: key,
            cacheKey: cacheKey,
            candidates: candidates
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
        // never once involves the bytes this now-stale snapshot was
        // taken alongside. Reuses `snapshot` (never a token) -- see this
        // function's own doc comment immediately above.
        guard await unchanged(since: snapshot, for: cacheKey) else {
            return try await asset(for: key)
        }
        await testOnlyPauseBeforeRevalidationRequest?()
        // Deliberately passes no `preIssuedAuthority` (defaults to
        // `nil`): nothing above ever reserved or issued any durable disk
        // authority (see this function's own doc comment above for why),
        // so there is nothing to forward. ``revalidateExisting``'s own
        // join-or-create decision derives and validates fresh authority
        // itself, from `validated`'s own historical stamp, but *only* on
        // the "create" branch -- a joiner uses whatever token the
        // in-flight operation it joins was issued when *it* started,
        // exactly as if this call had reserved nothing here at all. A
        // ``AssetError/revalidationProvenanceUnavailable`` thrown by
        // that join-or-create decision (`validated`'s historical stamp no
        // longer matching current durable reality by the time it
        // actually ran) *is* caught below, exactly like the quarantine
        // branch above: there is no longer any valid basis for a
        // conditional request, so this falls through to an ordinary
        // unconditional fetch exactly as if `validated` had never
        // existed, rather than surfacing a typed error this function's
        // own callers have no reason to expect from what looks, from the
        // outside, like an ordinary cache-miss continuation.
        do {
            return try await revalidateExisting(
                validated,
                key: key,
                cacheKey: cacheKey,
                candidates: candidates
            )
        } catch AssetError.revalidationProvenanceUnavailable {
            return try await coalescedFetch(key: key, cacheKey: cacheKey, candidates: candidates)
        }
    }
}
