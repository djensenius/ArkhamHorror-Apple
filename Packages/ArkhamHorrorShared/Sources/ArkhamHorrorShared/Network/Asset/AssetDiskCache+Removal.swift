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
            // The metadata pointer's deletion could not be confirmed: a
            // structurally-valid-looking entry may still be servable by
            // ``get(_:)`` afterward. This is no longer escalated to a
            // durable per-key tombstone or whole-cache disabled-reads
            // marker — see ``AssetDiskCache+Tombstone.swift``'s doc
            // comment for why that is no longer required: any such
            // residual bytes can never be trusted or served by
            // ``AssetCacheService`` without first passing a fresh online
            // conditional revalidation, so a failed local deletion can
            // never resurrect content the origin itself no longer serves.
            // The typed error thrown here still lets the caller maintain
            // its own in-process, best-effort tombstone
            // (``AssetCacheService/tombstonedKeys``) for the remainder of
            // this process's lifetime.
            throw error
        }
        cleanupSupersededPayloads(forKeyHash: key.digestHex, keeping: nil)
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
        // SecureCacheDirectory.lockFileName && name !=
        // SecureCacheDirectory.accessSequenceFileName && name !=
        // SecureCacheDirectory.clearEpochFileName` guard is what keeps
        // all three reserved files out of every removal pass here
        // (`listNames()`/`remove(name:)` themselves have no special-case
        // awareness of any of them): unlinking the lock file while this
        // very call still holds it open would detach every subsequent
        // `openat` of that name onto a fresh inode, silently breaking
        // cross-process mutual exclusion for everyone afterward; deleting
        // the durable access-sequence counter would let a value allocated
        // right after this clear collide with, or sort before, one
        // allocated before it, undoing
        // ``SecureCacheDirectory/allocateAccessSequence(atLeastAfter:)``'s
        // whole cross-instance monotonicity guarantee; deleting the
        // durable clear-epoch counter would reset every future reader
        // back to "never cleared", undoing this very call's own bump
        // below. Acquired and run directly on this actor's own executor,
        // same as ``remove(_:token:)``.
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        recoverOrphansIfNeeded()
        // Committed durably *before* any destructive removal work below,
        // and before this actor's own in-process generation bump: see
        // ``SecureCacheDirectory/bumpClearEpoch()``'s doc comment for why
        // this ordering (epoch first, destruction second) is required for
        // crash safety, and `SecureCacheDirectory+ClearEpoch.swift`'s
        // type-level doc comment for why this durable, cross-process
        // signal is what actually closes the cross-instance/cross-process
        // authority race a purely in-process generation counter alone
        // cannot: an independent ``AssetCacheService`` instance (or
        // process) sharing this same directory, whose fetch was issued
        // before this clear but whose publish only becomes ready after
        // it, re-reads this exact durable value (via
        // ``currentClearEpoch()``) as part of its own authority re-check
        // before ever publishing — including into its own private memory
        // cache, which this call has no other way of ever reaching.
        // A failure here throws immediately, before any removal work
        // begins: a caller must never observe "entries are already gone"
        // without the durable epoch having also already advanced.
        try secureDirectory.bumpClearEpoch()
        // Bumped before any removal work, exactly like
        // ``AssetMemoryCache/removeAll()``: any `set`/`touch`/`remove`
        // call bearing a token issued under an older generation is
        // rejected by ``acceptToken(_:for:)`` from this point on, even
        // if this actor happens to service it before the corresponding
        // `AssetCacheService`-level check would have caught it. This
        // in-process counter remains a useful fast-path optimization
        // (rejecting a stale write this exact actor instance already
        // knows is stale, without needing to re-read the durable epoch
        // file for it) layered on top of — never a substitute for — the
        // durable epoch bumped above, which is what actually protects a
        // *different* instance/process sharing this same directory.
        acceptedGeneration += 1
        appliedToken.removeAll()
        let names = try secureDirectory.listNames()
        var failureCount = 0
        for name in names where Self.isRemovableDuringClear(name) {
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

    /// The current durable, cross-instance/cross-process clear-epoch
    /// value for this cache directory — see
    /// `SecureCacheDirectory+ClearEpoch.swift`'s type-level doc comment.
    /// Acquires this cache's own exclusive lock for the read, exactly like
    /// every other access to durable shared state in this actor, so it can
    /// never observe a value `removeAll()` is only partway through
    /// committing on another instance/process. Cheap: a single small-file
    /// read under an already-necessary lock acquisition, not a full
    /// directory listing.
    func currentClearEpoch() async throws -> Int {
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        return secureDirectory.readPersistedClearEpoch()
    }

    /// `true` for any directory entry `removeAll()` is responsible for
    /// deleting -- every cache-owned entry except the shared lock file,
    /// the durable global access-sequence counter file, and the durable
    /// clear-epoch counter file, all three of which must survive a clear
    /// so a fresh process reopening this directory afterward still has a
    /// working cross-process lock, a monotonic counter that can never
    /// regress below a value some other instance may already have
    /// observed, and an intact record of every clear that has ever
    /// happened.
    private static func isRemovableDuringClear(_ name: String) -> Bool {
        name != SecureCacheDirectory.lockFileName
            && name != SecureCacheDirectory.accessSequenceFileName
            && name != SecureCacheDirectory.clearEpochFileName
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
