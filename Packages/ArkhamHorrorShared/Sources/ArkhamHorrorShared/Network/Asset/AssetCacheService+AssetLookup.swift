import Foundation

/// `AssetCacheService`'s primary public lookup entry point, split into
/// its own file purely to keep the main type declaration file under
/// this package's `file_length` limit alongside its stored properties
/// and test hooks.
extension AssetCacheService {
    /// Resolves `key` to a validated cached asset, serving from memory or
    /// disk when a valid entry already exists and otherwise performing (or
    /// joining an already in-flight) network fetch.
    ///
    /// A *memory* hit (already proven fresh earlier in this exact process
    /// run, and never surviving a restart) is returned immediately. A
    /// *disk-only* hit is different: this cache does not attempt to
    /// durably order writes across separate processes/instances sharing
    /// the same disk directory (see ``AssetDiskCache``'s doc comment), so
    /// persisted bytes from a possibly-different prior process are never
    /// independently trusted as still-fresh, offline-authoritative
    /// content — they are, at best, a conditional-revalidation candidate.
    /// Every disk-only hit must therefore pass the exact same structural
    /// re-validation as ``AssetCacheService/revalidateDiskHit(_:key:cacheKey:candidates:)``
    /// already performs, *and* a fresh online conditional
    /// (`ETag`/`Last-Modified`) revalidation against the live server,
    /// before it may ever be cached in memory or returned to a caller. If
    /// no validator is available at all (or the structural check already
    /// failed, or authority was lost mid-decode), this falls through to
    /// an ordinary unconditional fetch exactly as if this had been a
    /// clean cache miss — never silently serving unverified offline bytes.
    func asset(for key: AssetKey) async throws -> CachedAsset {
        let candidates = try resolvedCandidates(for: key)
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)

        // Snapshotted *before* the memory-cache read itself, mirroring the
        // disk-hit snapshot immediately below: `memoryCache.get` suspends
        // (a genuine hop to a different actor), during which a
        // more-recently-issued operation for this exact key — or a
        // cache-wide `evictAll()` — can become authoritative on *this*
        // actor without that having any effect on `memoryCache`'s own
        // already-in-flight `get` call. Without this check, such a race
        // could still hand back an entry this actor's own bookkeeping
        // already considers superseded, purely because of memory-cache
        // actor-hop timing luck. Wrapped in an authority window so this
        // key's bookkeeping cannot be pruned while this snapshot is still
        // suspended awaiting `memoryCache.get`.
        beginAuthorityWindow(for: cacheKey)
        let memorySnapshot = await snapshotAuthority(for: cacheKey)
        let memoryHit = await memoryCache.get(cacheKey)
        var memoryHitIsCurrent = false
        if let memoryHit {
            let stillUnchanged = await unchanged(since: memorySnapshot, for: cacheKey)
            let stillCurrentEpoch = await memoryEntryStillCurrent(
                memoryHit.durableClearEpoch,
                storedAuthorityID: memoryHit.authorityID,
                for: cacheKey
            )
            // Final synchronous, no-further-suspension re-check — see
            // ``localAuthorityStillMatchesSync(_:for:)``'s doc comment
            // for why this is required *in addition to* `stillUnchanged`
            // above: both `unchanged(since:for:)` and
            // `memoryEntryStillCurrent(_:storedAuthorityID:for:)` each
            // suspend at least once on their own durable disk round
            // trips, and a same-actor invalidation completing entirely
            // during one of those suspensions (before its own durable
            // counterpart has necessarily landed) would otherwise never
            // be observed before this memory hit is returned.
            await testOnlyPauseBeforeMemoryFinalCAS?()
            memoryHitIsCurrent = stillUnchanged
                && stillCurrentEpoch
                && localAuthorityStillMatchesSync(memorySnapshot, for: cacheKey)
        }
        endAuthorityWindow(for: cacheKey)
        if let cached = memoryHit, memoryHitIsCurrent {
            return cached
        }
        if let diskResult = try await diskHitIfTrusted(
            key: key,
            cacheKey: cacheKey,
            candidates: candidates
        ) {
            return diskResult
        }
        return try await coalescedFetch(key: key, cacheKey: cacheKey, candidates: candidates)
    }
}
