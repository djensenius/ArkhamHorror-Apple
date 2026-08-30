import Foundation

/// Whole-key and whole-cache removal for ``AssetDiskCache``, split out of
/// `AssetDiskCache.swift` purely to stay under this package's
/// `file_length` convention, the same way `AssetDiskCache+Recovery.swift`
/// and `AssetDiskCache+Read.swift` already are.
extension AssetDiskCache {
    /// Removes `key`'s metadata pointer (so it can never again be served
    /// by ``get(_:)``, regardless of whether any payload generation's
    /// bytes are still physically present on disk afterward), then
    /// best-effort sweeps every payload generation for it. Throws only if
    /// the metadata pointer itself could not be removed — that is the one
    /// failure the caller must react to (by tombstoning the key), since a
    /// leftover *payload* file with no metadata pointer referencing it can
    /// never be served by `get(_:)` and is simply reclaimed by the next
    /// orphan sweep. `token`, when supplied, gates this the same way as
    /// ``set(_:payload:metadata:token:)``: a stale removal request can
    /// never delete bytes a more-recently-issued operation just published.
    func remove(_ key: AssetCacheKey, token: AssetCacheService.CacheToken? = nil) async throws {
        // Single top-level lock acquisition, same convention as
        // ``set(_:payload:metadata:token:)``: acquired and run directly on
        // this actor's own executor, never via a closure passed into
        // `secureDirectory` (see ``SecureCacheDirectory/acquireExclusiveLock()``'s
        // doc comment for why that distinction matters).
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        recoverOrphansIfNeeded()
        if let token, !acceptToken(token, for: key) {
            return
        }
        do {
            _ = try secureDirectory.remove(name: metadataFilename(for: key))
            try secureDirectory.fsyncRootDirectory()
        } catch {
            // The metadata pointer's deletion could not be confirmed:
            // without a durable marker, ``get(_:)`` could still serve
            // this structurally-valid-looking, but supposedly
            // invalidated, entry — including across a restart, since
            // an in-memory-only tombstone does not survive one. Best-
            // effort persist the marker (itself inside this same held
            // lock) before rethrowing; a failure to even persist that
            // marker is surfaced identically (this call still throws
            // either way), letting the caller's own fail-closed
            // fallback (``AssetCacheService``'s whole-cache disabled
            // state) cover the residual gap.
            try? persistTombstoneLocked(keyHash: key.digestHex)
            throw error
        }
        cleanupSupersededPayloads(forKeyHash: key.digestHex, keeping: nil)
        // The metadata pointer is now durably confirmed gone: this is
        // itself the "durable clear" that supersedes any earlier
        // tombstone for this exact key.
        clearTombstoneLocked(keyHash: key.digestHex)
    }

    /// Removes every entry currently in the cache directory. Never deletes
    /// and recreates the directory itself (which would silently detach
    /// this cache's already-held root descriptor from the visible
    /// filesystem namespace, making every subsequent write invisible and
    /// unreclaimable until process exit) — instead unlinks each entry name
    /// individually. Collects (rather than stopping at) the first failure,
    /// so one unremovable entry can never mask every other entry that
    /// could be removed; throws a single aggregated failure if any
    /// removal (or the final directory `fsync`) failed, so the caller can
    /// still tombstone accordingly.
    ///
    /// A failure to even list the directory is itself surfaced (never
    /// swallowed into an empty list): treating a transient listing I/O
    /// error as "the cache is already empty" would let this method report
    /// success — and let a caller clear its own in-memory bookkeeping —
    /// while every actual entry remains fully present and servable on
    /// disk, breaking the "clear the cache" contract silently.
    func removeAll() async throws {
        // Wraps the *entire* clear inside the exclusive lock, exactly like
        // every other top-level mutation, so a concurrent `set`/`touch`/
        // `remove` (in this or another process/instance) can never
        // interleave with a clear in a way that resurrects an entry this
        // call intended to remove, or removes bytes a concurrent `set`
        // just published. This loop's own `where name !=
        // SecureCacheDirectory.lockFileName` guard is what keeps the lock
        // file itself out of every removal pass here (`listNames()`/
        // `remove(name:)` themselves have no special-case awareness of
        // it) — unlinking the lock file while this very call still holds
        // it open would detach every subsequent `openat` of that name
        // onto a fresh inode, silently breaking cross-process mutual
        // exclusion for everyone afterward. Acquired and run directly on
        // this actor's own executor, same as ``remove(_:token:)``.
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        recoverOrphansIfNeeded()
        // Bumped before any removal work, exactly like
        // ``AssetMemoryCache/removeAll()``: any `set`/`touch`/`remove`
        // call bearing a token issued under an older generation is
        // rejected by ``acceptToken(_:for:)`` from this point on, even
        // if this actor happens to service it before the corresponding
        // `AssetCacheService`-level check would have caught it.
        acceptedGeneration += 1
        appliedToken.removeAll()
        let names = try secureDirectory.listNames()
        var failureCount = 0
        for name in names where name != SecureCacheDirectory.lockFileName {
            do {
                _ = try secureDirectory.remove(name: name)
            } catch {
                failureCount += 1
            }
        }
        // A failed directory `fsync` here means the removals above
        // are not durably confirmed even though they already took
        // effect in this running process: counting it toward
        // `failureCount` (rather than swallowing it via `try?`) is
        // required so this method's own "clear cache" contract can
        // never silently report success while durability was not
        // actually achieved — and so callers like
        // ``AssetCacheService/evictAll()`` reliably take their own
        // failure/tombstoning path instead of clearing their
        // in-memory bookkeeping as if this had fully succeeded.
        do {
            try secureDirectory.fsyncRootDirectory()
        } catch {
            failureCount += 1
        }
        guard failureCount == 0 else {
            throw AssetError.cachePersistenceFailed(
                "\(failureCount) cache entries could not be removed, " +
                    "or the directory fsync failed"
            )
        }
    }

    /// The key hash embedded in every entry name currently present in the
    /// cache directory (metadata sidecars and payload generations alike),
    /// as a raw directory listing — deliberately cheaper than
    /// ``entries()``, which additionally reads and JSON-decodes every
    /// metadata sidecar: a caller that only needs "which keys have
    /// *something* on disk right now" (``AssetCacheService/evictAll()``'s
    /// conservative tombstone snapshot) has no need to pay that cost, and
    /// benefits from including even a corrupt/undecodable sidecar's key
    /// hash, which `entries()` would silently omit.
    ///
    /// Throws (rather than degrading to an empty result) if the directory
    /// cannot even be listed, so a caller can distinguish "the cache is
    /// genuinely empty" from "disk state could not be determined" — never
    /// silently treating the latter as the former.
    func entryKeyHashes() throws -> Set<String> {
        let names = try secureDirectory.listNames()
        var hashes: Set<String> = []
        for name in names {
            if name.hasSuffix(".meta.json") {
                hashes.insert(String(name.dropLast(".meta.json".count)))
            } else if name.hasSuffix(".bin"), let dotIndex = name.firstIndex(of: ".") {
                hashes.insert(String(name[name.startIndex ..< dotIndex]))
            }
        }
        return hashes
    }

    /// Total accounted bytes (payload + exact on-disk metadata size) across
    /// every currently valid entry. Used only by tests to assert exact
    /// quota accounting; production eviction re-derives this from disk
    /// directly so it never drifts from what is actually persisted.
    func totalAccountedBytes() -> Int {
        entries().reduce(0) { $0 + Self.accountedBytes(for: $1) }
    }
}
