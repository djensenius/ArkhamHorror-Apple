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
        guard
            let cached = diskHit,
            await unchanged(since: snapshot, for: cacheKey),
            !authorityIsRetiring(
                cached.authorityID,
                epoch: snapshot.durableClearEpoch,
                for: cacheKey
            )
        else {
            // Either a genuine disk miss, a disk hit whose read raced
            // with a more authoritative concurrent operation for this
            // exact key, or a disk hit whose own stamped generation has
            // already been decided (by some sibling cancellation/
            // retraction still in flight) to be retracted -- see
            // ``authorityIsRetiring(_:for:)``'s doc comment for why
            // ``unchanged(since:for:)`` alone cannot detect that last
            // case. All three fall through identically to a fresh
            // network fetch below, which issues (or joins) its own
            // currently-authoritative token.
            return nil
        }
        // **Deliberately reserves no durable per-key disk authority, and
        // issues no local token, here.** A prior revision either eagerly
        // reserved a fresh disk ticket via `beginRevalidationIssuance`,
        // or (an intermediate, still-broken revision of this exact fix)
        // called ``issueToken(for:)`` purely to have *something* to
        // compare this method's own post-decode fail-fast re-check
        // against below. Both are unsound, for related but distinct
        // reasons documented on this method's own doc comment above and
        // ``snapshotAuthority(for:)``'s: `issueToken(for:)`
        // unconditionally overwrites ``AssetCacheService/keyLatestToken``
        // for `cacheKey` the instant it is called — it is *never* a
        // no-op, exactly like a durable reservation is never a no-op —
        // so even this method's own purely-local decode-authority check
        // would itself durably clobber whatever token an already
        // in-flight coalesced revalidation for this exact key currently
        // depends on, the moment a second, ultimately-joining caller also
        // happened to reach this same code path. Concretely: caller A's
        // held revalidation registers its own token as
        // `keyLatestToken[cacheKey]`; caller B's disk-hit branch then
        // calls `issueToken(for:)` purely for its own local check,
        // silently replacing that entry with B's own token; caller A's
        // response, once released, then fails its own terminal
        // `isAuthoritative` check in
        // ``performRevalidation(_:)`` and is wrongly rejected as stale —
        // even though B genuinely only ever intended to *join* A's
        // operation, never supersede it.
        //
        // The fix reuses `snapshot` above — already a plain, read-only
        // capture with no side effects at all — for this method's own
        // post-decode re-check too (see
        // ``resolveTrustedDiskHit(_:key:cacheKey:candidates:snapshot:)``):
        // ``unchanged(since:for:)`` answers exactly the same question
        // ("has anything more authoritative for this key become current
        // since I started?") without ever writing to `keyLatestToken`
        // itself. Provenance validation and the actual fresh per-key
        // reservation (when one turns out to be needed at all) are both
        // deferred entirely to
        // ``coalescedRevalidation(cacheKey:url:expectedFormat:existing:preIssuedAuthority:)``'s
        // own join-or-create decision, which derives it fresh from
        // `cached`'s own historical stamp only on the "create" branch —
        // so a joiner truly reserves/issues nothing, anywhere.
        return try await resolveTrustedDiskHit(
            cached,
            key: key,
            cacheKey: cacheKey,
            candidates: candidates,
            snapshot: snapshot
        )
    }

    /// Continues ``diskHitIfTrusted(key:cacheKey:candidates:)`` once a
    /// structurally-plausible disk entry and the read-only authority
    /// `snapshot` taken before it was read are in hand: performs the
    /// mandatory online conditional revalidation and, on a definitive
    /// conditional 404, resumes the candidate walk at the very next
    /// candidate rather than treating the whole chain as exhausted. Split
    /// out purely to keep the caller's own body length within this
    /// package's convention; behavior and every authority/cancellation
    /// check below are otherwise unchanged from when this was inlined
    /// there directly.
    private func resolveTrustedDiskHit(
        _ cached: CachedAsset,
        key: AssetKey,
        cacheKey: AssetCacheKey,
        candidates: [AssetCandidate],
        snapshot: AuthoritySnapshot
    ) async throws -> CachedAsset? {
        guard let revalidated = try await revalidateDiskHit(
            cached,
            key: key,
            cacheKey: cacheKey,
            candidates: candidates
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
        // Reuses `snapshot` (captured once, before the disk read, by the
        // caller) rather than issuing any token of its own — see
        // ``diskHitIfTrusted(key:cacheKey:candidates:)``'s doc comment
        // for why a purely local check must never itself write to
        // ``AssetCacheService/keyLatestToken``.
        let target = conditionalRevalidationTarget(
            for: revalidated,
            key: key,
            candidates: candidates
        )
        guard
            await unchanged(since: snapshot, for: cacheKey),
            !authorityIsRetiring(
                revalidated.authorityID,
                epoch: snapshot.durableClearEpoch,
                for: cacheKey
            ),
            let target
        else {
            // Either something more authoritative for this key has
            // already superseded this snapshot, or there is no validator
            // to conditionally revalidate against at all: neither case
            // may trust this disk-only hit offline, so fall through to
            // an ordinary unconditional fetch below exactly as if this
            // had been a clean cache miss.
            return nil
        }
        // Structurally valid *and* a validator exists: require a fresh,
        // live conditional revalidation against the server before this
        // disk-only hit may ever be cached in memory or returned — see
        // this method's own doc comment for why a disk-only hit is never
        // independently trusted offline. `coalescedRevalidation` itself
        // performs the actual publish/touch on a successful outcome; a
        // thrown protocol/transport/cache error propagates straight out
        // rather than falling back to unverified local bytes.
        //
        // Deliberately passes no `preIssuedAuthority` (defaults to
        // `nil`): nothing above ever reserved or issued any durable disk
        // authority (see ``diskHitIfTrusted(key:cacheKey:candidates:)``'s
        // doc comment for why), so there is nothing to forward.
        // ``coalescedRevalidation``'s own join-or-create decision derives
        // and validates fresh authority itself, from `revalidated`'s own
        // historical stamp, but *only* on the "create" branch — a
        // joiner uses whatever token the in-flight operation it joins
        // was issued when *it* started, exactly as if this call had
        // reserved nothing here at all.
        do {
            return try await coalescedRevalidation(
                cacheKey: cacheKey,
                url: target.url,
                expectedFormat: target.format,
                existing: revalidated
            )
        } catch AssetError.revalidationProvenanceUnavailable {
            // `revalidated`'s own historical stamp no longer matches
            // current durable reality by the time the join-or-create
            // decision actually ran (superseded by a sibling clear or
            // competing write since this method's own decode/authority
            // checks above): there is no longer any valid basis for a
            // *conditional* request at all, so fall through to an
            // ordinary unconditional fetch below exactly as if this had
            // been a clean cache miss, mirroring
            // ``revalidate(for:)``'s identical memory-hit handling of
            // this same error.
            return nil
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
