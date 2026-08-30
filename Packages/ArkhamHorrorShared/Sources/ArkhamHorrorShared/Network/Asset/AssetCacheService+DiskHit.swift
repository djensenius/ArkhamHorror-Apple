import Foundation

/// The disk-hit branch of ``AssetCacheService/asset(for:)``, split into
/// its own file purely to keep `AssetCacheService.swift` itself within
/// this package's `file_length` convention.
extension AssetCacheService {
    /// The disk-hit branch of ``asset(for:)``: attempts a trusted,
    /// online-revalidated disk hit for `key`, returning `nil` (never
    /// throwing on a mere "nothing trustworthy here") whenever the caller
    /// should fall through to an ordinary network fetch exactly as if
    /// this had been a clean cache miss. Split out of ``asset(for:)``
    /// purely to keep that function's own body length within this
    /// package's convention; behavior (including every authority/
    /// cancellation check and doc comment below) is otherwise unchanged
    /// from when this was inlined there directly.
    func diskHitIfTrusted(
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate]
    ) async throws -> CachedAsset? {
        // A tombstoned key means this actor already intended to invalidate
        // its disk entry (a 404, a failed re-validation quarantine, or
        // `evictAll()`) — a purely in-process, best-effort optimization to
        // skip a disk read this actor already expects to be pointless, not
        // a correctness requirement: even an entry *not* skipped here must
        // still pass the mandatory online conditional revalidation below
        // before ever being trusted.
        guard !tombstonedKeys.contains(cacheKey) else {
            return nil
        }
        // Snapshotted *before* the disk read itself (not issued as a
        // token yet), so a subsequent mismatch can detect a more
        // -recently-issued operation for this exact key -- or
        // `evictAll()` -- that became authoritative while this disk
        // read was still in flight (the disk actor's own serialized
        // queue can run this `get` either before or after such an
        // operation's own disk-side effects, independent of the order
        // the two operations' tokens are issued in on *this* actor).
        // See ``snapshotAuthority(for:)``'s doc comment for why this
        // must not itself issue a token: a disk miss (or a hit that
        // loses this race) must never have consumed an issuance
        // number or superseded whatever fetch is legitimately already
        // in flight for this key, merely because a second,
        // ultimately-coalescing caller also passed through this same
        // code path. The whole disk-hit branch below (through the
        // structural revalidation and the authority check that
        // precedes the online conditional request) is one continuous
        // authority window: none of this key's bookkeeping may be
        // pruned while any of it is still suspended.
        beginAuthorityWindow(for: cacheKey)
        defer { endAuthorityWindow(for: cacheKey) }
        let snapshot = await snapshotAuthority(for: cacheKey)
        let diskHit = try await diskCache.get(cacheKey)
        guard let cached = diskHit, await unchanged(since: snapshot, for: cacheKey) else {
            // Either a genuine disk miss, or a disk hit whose read raced
            // with a more authoritative concurrent operation for this
            // exact key and so cannot be trusted or promoted -- both fall
            // through identically to a fresh network fetch below, which
            // issues (or joins) its own currently-authoritative token.
            return nil
        }
        // This disk-hit branch is never behind a coalescing dictionary,
        // so there is no "duplicate in-flight work" hazard to defer this
        // past — see ``issueToken(for:)``. This exact entry's own
        // *historical* clear-epoch/disk-write-generation provenance
        // (``AssetMemoryCache/CachedAsset/durableClearEpoch``/
        // ``AssetMemoryCache/CachedAsset/writeGeneration``, populated by
        // ``AssetDiskCache/get(_:)`` from
        // ``AssetCacheMetadata/clearEpochAtPublication``/
        // ``AssetCacheMetadata/writeGenerationAtPublication`` -- read
        // together with the payload under one locked disk-cache call) is
        // validated -- atomically, under one disk-cache lock hold,
        // alongside reserving this operation's own fresh authority -- via
        // ``beginRevalidationIssuance(for:historicalClearEpoch:historicalWriteGeneration:)``,
        // never threaded through directly as this operation's own token
        // (see that method's doc comment for why: doing so would break
        // ``AssetDiskCache/removeIfApplied(_:token:)``'s exact-match
        // cancellation-retraction contract). This ties this hit's own
        // eventual authority back to the moment its bytes were actually
        // confirmed fresh from origin, not to whatever epoch/ticket
        // merely happens to be current the instant it is read back.
        guard
            let historicalEpoch = cached.durableClearEpoch,
            let historicalGeneration = cached.writeGeneration,
            let preIssuedAuthority = await beginRevalidationIssuance(
                for: cacheKey,
                historicalClearEpoch: historicalEpoch,
                historicalWriteGeneration: historicalGeneration
            )
        else {
            // No historical provenance at all, a durable read failure, or
            // this entry's own historical stamp no longer matching
            // current durable reality: fail closed exactly like a
            // genuine disk miss, never fall back to a freshly-minted
            // "current" stamp.
            return nil
        }
        var token = issueToken(for: cacheKey)
        token.durableClearEpoch = preIssuedAuthority.clearEpoch
        token.diskWriteGeneration = preIssuedAuthority.diskWriteGeneration
        return try await resolveTrustedDiskHit(
            cached,
            key: key,
            cacheKey: cacheKey,
            candidates: candidates,
            token: token
        )
    }

    /// Continues ``diskHitIfTrusted(key:cacheKey:candidates:)`` once a
    /// structurally-plausible disk entry and its already-issued
    /// authority `token` are in hand: performs the mandatory online
    /// conditional revalidation and, on a definitive conditional 404,
    /// resumes the candidate walk at the very next candidate rather than
    /// treating the whole chain as exhausted. Split out purely to keep
    /// the caller's own body length within this package's convention;
    /// behavior and every authority/cancellation check below are
    /// otherwise unchanged from when this was inlined there directly.
    private func resolveTrustedDiskHit(
        _ cached: CachedAsset,
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate],
        token: CacheToken
    ) async throws -> CachedAsset? {
        guard let revalidated = try await revalidateDiskHit(
            cached,
            key: key,
            cacheKey: cacheKey,
            candidates: candidates,
            token: token
        ) else {
            // The persisted entry failed re-validation against the
            // *current* format/magic/dimension/limits/decode contract
            // (see ``revalidateDiskHit``): it has already been
            // quarantined (removed from disk), so fall through to a
            // fresh network fetch exactly as if nothing had been cached
            // at all, rather than surfacing the stale/invalid bytes or
            // poisoning this call permanently. `CancellationError` is
            // not caught here: `revalidateDiskHit` rethrows it rather
            // than returning `nil`, propagating straight out instead of
            // falling through.
            return nil
        }
        // `revalidateDiskHit` suspends (a full platform decode);
        // re-check this key's authority immediately before doing
        // anything further — a `evictAll()` or a more-recently-issued
        // operation for this exact key may already have concluded while
        // this suspension was in progress, and proceeding to serve (even
        // after an online revalidation) content this actor's own
        // bookkeeping already considers superseded would let a caller
        // observe stale state. If not authoritative, fall through to a
        // fresh network fetch below exactly like a genuine cache miss.
        let target = conditionalRevalidationTarget(
            for: revalidated,
            key: key,
            candidates: candidates
        )
        guard await isAuthoritative(token, for: cacheKey), let target else {
            // Either this token already lost authority, or there is no
            // validator to conditionally revalidate against at all:
            // neither case may trust this disk-only hit offline, so fall
            // through to an ordinary unconditional fetch below exactly
            // as if this had been a clean cache miss.
            return nil
        }
        // Structurally valid *and* a validator exists: require a fresh,
        // live conditional revalidation against the server before this
        // disk-only hit may ever be cached in memory or returned — see
        // this method's own doc comment for why a disk-only hit is never
        // independently trusted offline. `coalescedRevalidation` itself
        // performs the actual publish/touch on a successful outcome; a
        // thrown protocol/transport/cache error propagates straight out
        // rather than falling back to unverified local bytes. Passes
        // only `token`'s durable clear-epoch/disk-write-generation
        // snapshot (never `token` itself) — see
        // ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:preIssuedAuthority:)``'s
        // doc comment for why forwarding this branch's own
        // already-issued token (reserved above purely for its own
        // decode-authority re-check) would clobber whatever token an
        // already in-flight coalesced revalidation for this key is
        // relying on, and why this authority must be carried straight
        // through unchanged rather than re-derived from `revalidated` a
        // second time later (that would move this operation's own
        // issuance moment past whatever caller-installed pause a test
        // might inject between here and the eventual network step,
        // changing which typed error a race exactly there produces).
        do {
            return try await coalescedRevalidation(
                cacheKey: cacheKey,
                url: target.url,
                expectedFormat: target.format,
                existing: revalidated,
                preIssuedAuthority: PreIssuedAuthority(
                    clearEpoch: token.durableClearEpoch,
                    diskWriteGeneration: token.diskWriteGeneration
                )
            )
        } catch AssetError.candidatesExhausted {
            // `performRevalidation`'s `.notFound` branch only ever
            // throws `candidatesExhausted` after an authoritative
            // conditional 404 for this *one* resolved candidate has
            // already been durably invalidated from both cache layers
            // (any staleness race there instead surfaces as
            // `staleOperation`, caught by neither this clause nor
            // falling through below — it propagates straight out). That
            // says nothing about this key's *other* candidates (an
            // English fallback, or an alternate front image): only this
            // exact candidate was ever requested, so treating its own
            // removal as if the entire chain were exhausted would
            // wrongly make whether a still-perfectly-available English
            // asset gets served depend on unrelated cache history
            // (whether a *localized* variant happened to be cached
            // before). Resume an ordinary candidate walk starting
            // immediately after the now-confirmed-gone one; if it was
            // already the last candidate, there is nothing left to try
            // and this rethrows the same error, correctly reporting
            // genuine exhaustion.
            let remaining = Array(candidates[(target.candidateIndex + 1)...])
            guard !remaining.isEmpty else {
                throw AssetError.candidatesExhausted
            }
            return try await coalescedFetch(
                key: key,
                cacheKey: cacheKey,
                candidates: remaining
            )
        }
    }
}
