import Foundation

/// Whole-key and whole-cache removal for ``AssetDiskCache``, split out of
/// `AssetDiskCache.swift` purely to stay under this package's
/// `file_length` convention, the same way `AssetDiskCache+Recovery.swift`
/// and `AssetDiskCache+Read.swift` already are.
extension AssetDiskCache {
    /// Durably commits a `.retiring` then `.tombstone` disposition for
    /// `key` (see ``commitRetractionLocked(for:token:destroy:)``), so it
    /// can never again be served by ``get(_:)`` regardless of whether any
    /// metadata pointer or payload generation's bytes are still
    /// physically present on disk afterward, then best-effort attempts to
    /// actually delete the metadata pointer and every payload generation.
    /// Throws only if the durable disposition transaction itself could
    /// not be committed (a state-write or its confirming `fsync` failed)
    /// — that is the one failure a caller must react to as a genuine,
    /// non-`.applied` outcome (see ``AssetCacheService/invalidate(_:token:)``'s
    /// own doc comment); a mere physical-deletion failure is intentionally
    /// never surfaced here, since the durable `.tombstone` disposition
    /// alone is what actually makes this key's prior content unreadable
    /// from this point on, and any leftover bytes a failed deletion left
    /// behind are simply reclaimed by the next orphan sweep. `token`,
    /// when supplied, gates this the same way as
    /// ``set(_:payload:metadata:token:)``: a stale removal request never
    /// deletes bytes a more-recently-issued operation just published —
    /// returns ``AssetCacheService/MutationOutcome/stale`` (not a silent
    /// `Void` success) in that case.
    @discardableResult
    func remove(
        _ key: AssetCacheKey,
        token: AssetCacheService.CacheToken? = nil
    ) async throws -> AssetCacheService.MutationOutcome {
        // Single top-level lock acquisition, same convention as
        // ``set(_:payload:metadata:token:)``: acquired and run directly on
        // this actor's own executor, never via a closure passed into
        // `secureDirectory` (see ``SecureCacheDirectory/acquireExclusiveLock()``'s
        // doc comment for why that distinction matters).
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        let currentEpoch = try secureDirectory.readPersistedClearEpoch()
        let currentIssued = try currentIssuedTicketLocked(for: key)
        if let token {
            guard acceptToken(
                token,
                currentEpoch: currentEpoch,
                currentIssued: currentIssued
            ) else {
                return .stale
            }
        }
        // Two-phase, crash-safe removal via
        // ``commitRetractionLocked(for:token:destroy:)``: durably commits
        // `.retiring(ticket)` *before* this closure ever runs, then
        // `.tombstone(ticket)` only once it returns. Physical deletion
        // itself is deliberately best-effort (`try?`) here, never
        // propagated: once the final `.tombstone` commit below lands
        // durably, this key is unreadable by ``get(_:)`` regardless of
        // whether the metadata sidecar or any payload generation happens
        // to still be physically present -- a caller (``AssetCacheService/invalidate(_:token:)``)
        // must only ever see this call throw for a genuine failure to
        // commit the *disposition itself* (the two durable JSON writes
        // above), which is the one failure that must actually prevent
        // reporting this definitive removal as applied or advancing a
        // fallback candidate chain. A prior revision instead let a mere
        // physical-deletion failure escape this call entirely,
        // indistinguishable from a disposition-commit failure to this
        // method's own caller — collapsing "the durable tombstone landed
        // but some stray bytes could not be swept" together with "the
        // durable tombstone itself never landed at all", which is
        // exactly the ambiguity this whole two-phase disposition model
        // exists to remove.
        try commitRetractionLocked(for: key, token: token) {
            _ = try? self.secureDirectory.remove(name: self.metadataFilename(for: key))
            try? self.secureDirectory.fsyncRootDirectory()
            self.cleanupSupersededPayloads(forKeyHash: key.digestHex, keeping: nil)
        }
        return .applied
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
        // SecureCacheDirectory.clearEpochFileName && name !=
        // SecureCacheDirectory.rootInitMarkerFileName && name !=
        // SecureCacheDirectory.rootFreshnessWitnessFileName` guard is what
        // keeps all five reserved files out of every removal pass here
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
        // below; deleting the root-init marker would let a future missing
        // clear-epoch counter be wrongly treated as a genuinely pristine
        // root again (see ``SecureCacheDirectory/ensureRootAuthorityInitializedLocked()``);
        // deleting the root-freshness witness would strip an already-used,
        // since-cleared root of its only remaining durable proof of ever
        // having been fresh, permanently and incorrectly fail-closing its
        // very next authority check the moment both authority files were
        // ever simultaneously lost.
        // Acquired and run directly on this actor's own executor,
        // same as ``remove(_:token:)``.
        //
        // Every failure between this point and the durable clear-epoch
        // bump below (lock acquisition itself, root-authority
        // initialization, or -- via ``ensureRootAuthorityInitializedLocked()``'s
        // own internal wrapping -- any read failure encountered while
        // determining that root's state) is normalized to
        // ``AssetError/clearFenceNotDurable(_:)`` rather than left as
        // whatever raw error type happened to surface -- **including**
        // ``CancellationError``. A prior revision rethrew a cancellation
        // encountered here completely unchanged, on the theory that "a
        // cancelled clear is not a persistence failure at all" -- but
        // that reasoning only holds for a cancellation observed *after*
        // the durable fence below has already committed (this method has
        // exactly one suspension point before that commit: acquiring the
        // lock itself). A `Task` cancelled while waiting on that lock has
        // no way to know whether the fence will ever actually land --
        // this method simply returns without ever reaching
        // ``SecureCacheDirectory/bumpClearEpoch()`` -- so from
        // ``AssetCacheService/evictAll()``'s own perspective this is
        // indistinguishable from any other pre-fence failure: local,
        // in-process bookkeeping (already-cleared memory entries,
        // in-flight waiters) must not be trusted as if a durable,
        // cross-instance/cross-process fence had actually been committed.
        // Reporting it as plain, untyped ``CancellationError`` instead let
        // a caller's generic `catch` silently treat this identically to
        // "cancellation is always safe to ignore" and proceed as though
        // nothing durable was at stake -- exactly the "pre-fence failures
        // are swallowed" gap a prior review flagged, just for one
        // specific error type the previous fix's catch-all deliberately
        // carved back out. Only a cancellation observed strictly *after*
        // the fence has already durably committed (there is no such
        // suspension point remaining in this method once the lock is
        // held -- everything from root-authority initialization through
        // the final directory `fsync` below is synchronous Darwin I/O) is
        // ever an ordinary, non-fence-related cancellation; this method
        // has no such window to preserve.
        let lockFD: Int32
        do {
            lockFD = try await secureDirectory.acquireExclusiveLock()
        } catch {
            throw AssetError.clearFenceNotDurable(
                "Could not acquire the cross-process lock before the clear fence: \(error)"
            )
        }
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        do {
            try ensureRootAuthorityInitializedLocked()
        } catch let error as AssetError {
            throw error
        } catch {
            throw AssetError.clearFenceNotDurable(
                "Root-authority initialization failed before the clear fence: \(error)"
            )
        }
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
        // Every per-key durable issuance/applied ticket counter file
        // (`.gen`/`.applied`, see `AssetDiskCache+WriteGeneration.swift`)
        // is deliberately *not* specially reserved here the way the
        // lock/access-sequence/clear-epoch files are: this clear's own
        // epoch bump above already durably fences every token issued
        // before it (any such token's ``AssetCacheService/CacheToken/durableClearEpoch``
        // can never again match, regardless of what its
        // ``AssetCacheService/CacheToken/diskWriteGeneration`` says), so
        // letting the removal pass below sweep away every `.gen`/
        // `.applied` file too is both safe and desirable: it lets every
        // key restart from a clean ticket baseline after a real clear,
        // rather than accumulating two small counter files per key ever
        // written for the lifetime of this cache directory.
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
        try ensureRootAuthorityInitializedLocked()
        return try secureDirectory.readPersistedClearEpoch()
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
            && name != SecureCacheDirectory.rootInitMarkerFileName
            && name != SecureCacheDirectory.rootFreshnessWitnessFileName
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
