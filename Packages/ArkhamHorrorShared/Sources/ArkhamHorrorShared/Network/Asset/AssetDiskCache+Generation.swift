import Foundation

/// The durable, cross-process half of ``AssetDiskCache``'s write
/// compare-and-swap, split out of `AssetDiskCache.swift` purely to stay
/// under this package's `file_length` convention.
///
/// ``AssetDiskCache/acceptToken(_:for:)`` (and
/// ``AssetCacheService/CacheToken``'s `generation`/`issuance` fields it
/// compares) is a purely **in-process** authority: each separate process
/// or instance pointed at this same cache directory starts its own
/// issuance counters independently from zero, so those values are never
/// meaningfully comparable across two such instances. Two overlapping
/// writes for the same key, issued by two different processes, can
/// therefore both sail past that in-process check — each is the "latest"
/// as far as its own process's bookkeeping is concerned — and whichever
/// one's write happens to reach disk last simply wins, even if it started
/// its work *before* the one that already durably committed a fresher
/// result.
///
/// ``AssetCacheMetadata/writeGeneration`` and this file's functions close
/// that gap by moving the ordering signal itself onto disk, where every
/// instance/process can read and compare it. Each fresh (non-coalesced)
/// operation captures the *current* durable write-generation for its key
/// once, up front — before it ever performs the network I/O unique to its
/// own attempt (see
/// ``AssetCacheService/withDiskBaseline(_:for:)``) — into
/// ``AssetCacheService/CacheToken/diskBaselineGeneration``. Every later
/// write for that key (``AssetDiskCache/setLocked(_:payload:metadata:token:)``,
/// ``AssetDiskCache/touchLocked(_:metadata:token:)``,
/// ``AssetDiskCache/Removal/remove(_:token:)``) is only accepted, inside
/// this cache's single exclusive lock, if that captured value is still
/// exactly the durable generation this key currently has: if it is not,
/// some other write — from this process or another — has already been
/// durably committed since this operation started, and this one is a
/// stale no-op instead. This is textbook optimistic concurrency control
/// (the same shape as an `ETag`-based conditional write), not a claim
/// that this cache can recover a true, wall-clock cross-process issuance
/// order without a shared linearizable clock; the property that actually
/// matters — a write based on stale information can never clobber one
/// based on fresher, durably-observed information — holds regardless.
///
/// A removal must durably advance this generation *past* whatever was
/// live at the moment of removal (never merely delete the metadata that
/// carried it): otherwise a stale in-flight write whose baseline matches
/// the now-deleted generation could still land afterward and resurrect
/// the just-invalidated bytes. See
/// ``AssetDiskCache/Removal/remove(_:token:)``'s fence-tombstone write for
/// where that fence is persisted, and
/// ``AssetDiskCache/Tombstone/tombstoneFenceLocked(keyHash:)`` for how it
/// is read back.
extension AssetDiskCache {
    /// The maximum size ever expected for a tombstone marker's fence-
    /// generation content — a small, fixed-width decimal integer, never
    /// unbounded input. Bounds the read the same way every other on-disk
    /// read in this cache is bounded.
    static let maxTombstoneFenceBytes = 32

    /// Reads `key`'s current durable on-disk write-generation, acquiring
    /// this cache's own exclusive lock itself. This is the function
    /// ``AssetCacheService/withDiskBaseline(_:for:)`` calls to capture a
    /// fresh operation's baseline; see this file's own doc comment for
    /// the full contract.
    func currentWriteGeneration(for key: AssetCacheKey) async -> Int {
        guard let lockFD = try? await secureDirectory.acquireExclusiveLock() else {
            // Same fail-safe reasoning as every other best-effort lock
            // acquisition in this cache: a baseline this operation could
            // not even read is safest treated as "unknown, definitely not
            // stale" (0) rather than blocking the caller entirely --
            // ``acceptDurableGeneration(_:for:)`` below independently
            // still protects the eventual write itself, since it performs
            // its own fresh read under a lock it *does* successfully hold.
            return 0
        }
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        recoverOrphansIfNeeded()
        return currentWriteGenerationLocked(for: key)
    }

    /// Same read as ``currentWriteGeneration(for:)``, but for use from
    /// *inside* an already-held lock (``setLocked``/``touchLocked``/
    /// ``remove(_:token:)``) — never acquires the lock itself. Checks a
    /// durable tombstone fence first (a prior removal's own record of
    /// what generation it advanced past), then a currently valid metadata
    /// sidecar's own ``AssetCacheMetadata/writeGeneration``, defaulting to
    /// `0` if this key has never been written.
    func currentWriteGenerationLocked(for key: AssetCacheKey) -> Int {
        if let fence = tombstoneFenceLocked(keyHash: key.digestHex) {
            return fence
        }
        let metadataName = metadataFilename(for: key)
        guard let data = try? secureDirectory.read(
            name: metadataName,
            maxBytes: SecureCacheDirectory.maxMetadataBytes
        ) else {
            return 0
        }
        let decoder = JSONDecoder.assetCache()
        guard
            let metadata = try? decoder.decode(AssetCacheMetadata.self, from: data),
            metadata.schemaVersion == AssetCacheMetadata.currentSchemaVersion,
            metadata.cacheKeyHex == key.digestHex
        else {
            // Something invalid occupies this exact, hash-derived name --
            // quarantine it here rather than silently repeating this
            // failed read on every future write attempt for this key
            // (mirrors ``AssetDiskCache/Read``'s own quarantine-on-corrupt
            // convention). A generation of `0` is unambiguous once this
            // is gone: there is now nothing durably recorded for this key.
            quarantine(keyHash: key.digestHex, metadataName: metadataName)
            return 0
        }
        return metadata.writeGeneration
    }

    /// The durable half of the write compare-and-swap: `true` only if
    /// `token.diskBaselineGeneration` still matches `key`'s current
    /// durable on-disk write-generation, read fresh inside this already-
    /// held lock. A mismatch means some other write — in this process or
    /// a different one — has already been durably committed for this key
    /// since `token` captured its baseline, so the caller must treat this
    /// exactly like an ``acceptToken(_:for:)`` rejection: a silent no-op,
    /// never a thrown error (a lost race is an ordinary, expected
    /// outcome, not a malfunction).
    func acceptDurableGeneration(
        _ token: AssetCacheService.CacheToken,
        for key: AssetCacheKey
    ) -> Bool {
        token.diskBaselineGeneration == currentWriteGenerationLocked(for: key)
    }

    /// `currentWriteGenerationLocked(for:) + 1`, computed safely: every
    /// call site that advances this key's durable generation (a fresh
    /// publish in ``commitMetadataPointerLocked(_:metadata:payloadName:payloadAlreadyExisted:)``,
    /// a removal's fence in ``remove(_:token:)``) needs exactly this next
    /// value, never the bare current one. `currentWriteGenerationLocked(for:)`
    /// deliberately returns the fail-closed sentinel `Int.max` whenever
    /// this key's durable state could not be confirmed (an unreadable
    /// tombstone marker, or one present but unparsable) -- a real,
    /// reachable outcome of nothing more exotic than a transient
    /// permission or I/O failure on that one file, not a programming
    /// error. Blindly adding `1` to that sentinel is undefined-in-intent
    /// and, in an unchecked build, a genuine `Int` overflow trap: a single
    /// unreadable tombstone would crash the process instead of merely
    /// failing this one write. Throws the same typed
    /// ``AssetError/cachePersistenceFailed(_:)`` every other confirmable
    /// failure in this cache surfaces as, so the fail-closed sentinel
    /// keeps failing writes closed rather than crashing them.
    func nextWriteGenerationLocked(for key: AssetCacheKey) throws -> Int {
        let current = currentWriteGenerationLocked(for: key)
        guard current != Int.max else {
            throw AssetError.cachePersistenceFailed(
                "key's durable write-generation could not be confirmed"
            )
        }
        return current + 1
    }
}
