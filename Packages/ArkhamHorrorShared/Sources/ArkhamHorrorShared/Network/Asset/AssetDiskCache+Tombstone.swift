import Foundation

/// Durable per-key tombstones and the whole-cache "fail closed" marker for
/// ``AssetDiskCache``, split out of `AssetDiskCache.swift` purely to stay
/// under this package's `file_length` convention, the same way
/// `AssetDiskCache+Recovery.swift` and `AssetDiskCache+Read.swift` already
/// are.
///
/// Both mechanisms exist to survive a process restart: an in-memory-only
/// tombstone set (as ``AssetCacheService`` also maintains, defense in
/// depth) is lost the moment the process exits, but a failed metadata
/// -pointer deletion can leave structurally-valid-looking bytes on disk
/// that a fresh instance's ``AssetDiskCache/get(_:)`` would otherwise
/// happily serve again. A small, durable marker file — written with the
/// exact same write/fsync/rename/fsync sequence as any other cache entry —
/// closes that gap without requiring any separate startup reconciliation
/// step: `get(_:)` simply checks for the marker's existence before
/// trusting anything else about the entry.
extension AssetDiskCache {
    /// The durable, on-disk marker for a key whose invalidation could not
    /// be confirmed to fully remove its metadata pointer — see
    /// ``persistTombstoneLocked(keyHash:)``'s doc comment for the full
    /// contract this supports.
    func tombstoneFilename(keyHash: String) -> String {
        "\(keyHash).tombstone"
    }

    /// The single, fixed-name, whole-cache "fail closed" marker: present
    /// only when this cache could not durably confirm *which* specific
    /// keys needed protecting after a failure (an unenumerable
    /// ``removeAll()`` survivor listing) — see
    /// ``markDiskReadsDisabledLocked()``.
    static let diskReadsDisabledMarkerName = ".disk-reads-disabled"

    /// `true` if `keyHash` has a durable tombstone marker on disk — see
    /// ``persistTombstoneLocked(keyHash:)``. Checked by ``get(_:)`` before
    /// ever trusting a structurally-valid metadata+payload pair for this
    /// key: an entry whose metadata pointer *deletion* previously failed
    /// (leaving valid-looking bytes still on disk) must never be served
    /// again regardless of what a purely structural read would otherwise
    /// accept.
    func isTombstoned(keyHash: String) -> Bool {
        do {
            return try secureDirectory.attributes(name: tombstoneFilename(keyHash: keyHash)) != nil
        } catch {
            // `attributes(name:)` throws only for a genuine `fstatat`
            // failure other than "does not exist" (permission, I/O,
            // etc.) — it already returns `nil` (not thrown) for ENOENT.
            // Collapsing that thrown failure into "no tombstone" via
            // `try?` would fail *open*: exactly the outcome this marker
            // exists to prevent. Since a tombstone's entire purpose is to
            // durably prevent serving an entry whose invalidation could
            // not otherwise be confirmed, an inability to even check for
            // one must be treated the same as finding one present.
            return true
        }
    }

    /// `true` if this whole cache's disk reads are currently disabled —
    /// see ``markDiskReadsDisabledLocked()``. Checked by ``get(_:)`` before
    /// any other work, ahead of even the per-key ``isTombstoned(keyHash:)``
    /// check.
    func areDiskReadsDisabled() -> Bool {
        do {
            return try secureDirectory.attributes(name: Self.diskReadsDisabledMarkerName) != nil
        } catch {
            // Same fail-closed reasoning as ``isTombstoned(keyHash:)``: a
            // genuine `fstatat` failure (not "marker absent") must never
            // be treated as "disk reads are enabled" — this marker exists
            // specifically to force the fail-closed path when this
            // cache's state cannot otherwise be trusted, so an inability
            // to even check for it is itself a reason to stay disabled.
            return true
        }
    }

    /// Best-effort marks the *entire* cache's disk reads as disabled: the
    /// last-resort "fail closed" fallback for when this cache cannot even
    /// durably confirm which specific key(s) needed a tombstone — for
    /// example ``AssetCacheService/evictAll()``'s survivor-enumeration
    /// failure path, where a failed ``removeAll()`` also could not even
    /// list what (if anything) physically remains. Every subsequent
    /// ``get(_:)`` call refuses to serve *any* entry while this marker is
    /// present, regardless of that entry's own validity, until a fully
    /// successful ``removeAll()`` later removes it (the one event this
    /// cache treats as a durable, whole-cache "clear/replacement").
    /// Deliberately swallows its own failure (there is nothing further to
    /// fall back to if even this write fails); the caller's own
    /// in-process `diskReadsDisabled`-equivalent state is expected to
    /// cover that residual gap for the lifetime of the current process.
    ///
    /// Acquires the exclusive lock itself (unlike the `Locked`-suffixed
    /// helpers above): called from ``AssetCacheService/evictAll()``, which
    /// is not already inside any ``AssetDiskCache`` critical section at
    /// that point.
    func markDiskReadsDisabled() async {
        guard let lockFD = try? await secureDirectory.acquireExclusiveLock() else {
            return
        }
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        markDiskReadsDisabledLocked()
    }

    /// Same marker write as ``markDiskReadsDisabled()``, but for use from
    /// *inside* an already-held lock (currently unused directly, kept
    /// alongside the locked/unlocked pair convention established by
    /// ``persistTombstoneLocked(keyHash:)``/``clearTombstoneLocked(keyHash:)``
    /// for symmetry and any future locked call site).
    private func markDiskReadsDisabledLocked() {
        let name = Self.diskReadsDisabledMarkerName
        _ = try? secureDirectory.writeTempAndFsync(tempName: name + ".tmp", data: Data())
        _ = try? secureDirectory.renameAndFsyncDirectory(from: name + ".tmp", to: name)
    }

    /// Durably marks `keyHash` as invalidated: an empty marker file,
    /// written/fsynced/renamed/fsynced exactly like any other entry write
    /// this cache performs, so it survives a crash immediately after this
    /// call returns exactly as reliably as a payload generation does.
    /// Must be called from *inside* an already-held
    /// ``SecureCacheDirectory/withExclusiveLock(_:)`` critical section
    /// (never acquires the lock itself — `flock` is not reentrant across
    /// separate opens of the same lock file even within one process).
    ///
    /// This is the mechanism that lets a failed metadata-pointer deletion
    /// (``AssetDiskCache/Removal/remove(_:token:)``'s catch path) still
    /// durably prevent ``get(_:)`` from ever serving the
    /// structurally-valid-looking bytes that deletion failure left
    /// behind — without it, a subsequent read would have no way to know
    /// this exact entry was supposed to be gone.
    func persistTombstoneLocked(keyHash: String) throws {
        let name = tombstoneFilename(keyHash: keyHash)
        let tempName = name + ".tmp"
        try secureDirectory.writeTempAndFsync(tempName: tempName, data: Data())
        try secureDirectory.renameAndFsyncDirectory(from: tempName, to: name)
    }

    /// Best-effort removes `keyHash`'s durable tombstone marker (if any).
    /// Called once a fresh, successful generation has actually been
    /// published for this exact key (``set(_:payload:metadata:token:)``'s
    /// final step) — a definitively fresh, verified write supersedes
    /// whatever an earlier failed deletion was protecting against. Must
    /// be called from inside an already-held lock, exactly like
    /// ``persistTombstoneLocked(keyHash:)``.
    func clearTombstoneLocked(keyHash: String) {
        _ = try? secureDirectory.remove(name: tombstoneFilename(keyHash: keyHash))
        try? secureDirectory.fsyncRootDirectory()
    }
}
