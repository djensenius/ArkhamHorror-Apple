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
        tombstoneFenceLocked(keyHash: keyHash) != nil
    }

    /// Reads `keyHash`'s durable tombstone marker's *fence generation* —
    /// the write-generation a prior ``AssetDiskCache/Removal/remove(_:token:)``
    /// durably recorded as having been advanced past (see
    /// `AssetDiskCache+Generation.swift`'s doc comment for the full write
    /// compare-and-swap contract this supports). Returns `nil` only when
    /// no tombstone marker exists at all for this key; `Int.max` — a
    /// fence no legitimate ``AssetCacheService/CacheToken/diskBaselineGeneration``
    /// can ever equal — if a marker exists but its content could not be
    /// read/parsed, or if even checking for its existence failed.
    ///
    /// This exact fail-closed shape (present-but-unreadable treated
    /// identically to present-and-valid, never as "absent") is what
    /// ``isTombstoned(keyHash:)`` above already relied on before this
    /// method existed; both a `get(_:)` serve-gate and a durable write
    /// CAS need the same "an inability to confirm this marker's state is
    /// itself reason to refuse" behavior, so this single implementation
    /// backs both.
    func tombstoneFenceLocked(keyHash: String) -> Int? {
        let name = tombstoneFilename(keyHash: keyHash)
        let exists: Bool
        do {
            exists = try secureDirectory.attributes(name: name) != nil
        } catch {
            // `attributes(name:)` throws only for a genuine `fstatat`
            // failure other than "does not exist" (permission, I/O,
            // etc.) — it already returns `nil` (not thrown) for ENOENT.
            // Collapsing that thrown failure into "no tombstone" via
            // `try?` would fail *open*: exactly the outcome this marker
            // exists to prevent.
            return .max
        }
        guard exists else { return nil }
        guard
            let data = try? secureDirectory.read(
                name: name,
                maxBytes: AssetDiskCache.maxTombstoneFenceBytes
            ),
            let text = String(data: data, encoding: .utf8),
            let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            value >= 0
        else {
            // The marker exists but its content is missing, unreadable,
            // or not a valid non-negative fence generation -- fail closed
            // exactly like an `attributes(name:)` failure above, never
            // treated as "no protection needed here".
            return .max
        }
        return value
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
    /// *inside* an already-held lock — called by
    /// ``AssetDiskCache/Removal/remove(_:token:)``'s own catch block when
    /// its own ``persistTombstoneLocked(keyHash:)`` attempt also fails
    /// (this key's own durable protection could not be established at
    /// all, so the whole-cache fail-closed marker is the only remaining
    /// option), alongside the locked/unlocked pair convention established
    /// by ``persistTombstoneLocked(keyHash:)``/``clearTombstoneLocked(keyHash:)``.
    func markDiskReadsDisabledLocked() {
        let name = Self.diskReadsDisabledMarkerName
        _ = try? secureDirectory.writeTempAndFsync(tempName: name + ".tmp", data: Data())
        _ = try? secureDirectory.renameAndFsyncDirectory(from: name + ".tmp", to: name)
    }

    /// Durably marks `keyHash` as invalidated, with `fenceGeneration` as
    /// its content — written/fsynced/renamed/fsynced exactly like any
    /// other entry write this cache performs, so it survives a crash
    /// immediately after this call returns exactly as reliably as a
    /// payload generation does. Must be called from *inside* an
    /// already-held ``SecureCacheDirectory/withExclusiveLock(_:)``
    /// critical section (never acquires the lock itself — `flock` is not
    /// reentrant across separate opens of the same lock file even within
    /// one process).
    ///
    /// This serves two distinct purposes, both required by
    /// ``AssetDiskCache/Removal/remove(_:token:)``: it lets a failed
    /// metadata-pointer deletion still durably prevent ``get(_:)`` from
    /// ever serving the structurally-valid-looking bytes that deletion
    /// failure left behind, *and* — via `fenceGeneration` — it durably
    /// records the write-generation this removal advanced past, so a
    /// stale in-flight write whose captured baseline still matches the
    /// now-removed generation can never resurrect it even after this
    /// deletion fully succeeds (see `AssetDiskCache+Generation.swift`'s
    /// doc comment for the full contract).
    func persistTombstoneLocked(keyHash: String, fenceGeneration: Int) throws {
        let name = tombstoneFilename(keyHash: keyHash)
        let tempName = name + ".tmp"
        let content = Data(String(fenceGeneration).utf8)
        try secureDirectory.writeTempAndFsync(tempName: tempName, data: content)
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
