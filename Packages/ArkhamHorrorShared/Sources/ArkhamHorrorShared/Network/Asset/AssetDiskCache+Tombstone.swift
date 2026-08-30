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

    /// The single, fixed-name, whole-cache "fail closed for writes"
    /// marker: present only when ``evictIfNeeded()`` could not durably
    /// confirm this cache's *total physical on-disk usage* is within
    /// ``AssetCacheLimits/highWaterMarkDiskBytes`` — either because the
    /// directory could not even be enumerated/accounted for, or because a
    /// full eviction pass still could not bring accounted usage back
    /// under budget (e.g. persistent removal failures). Distinct from
    /// ``diskReadsDisabledMarkerName``: reads being disabled protects
    /// against *serving* possibly-invalidated bytes, while writes being
    /// disabled protects against *accepting new bytes* while this cache's
    /// disk budget is provably unbounded/unknown — see
    /// ``AssetDiskCache/requireDiskWritesEnabledLocked()``.
    static let diskWritesDisabledMarkerName = ".disk-writes-disabled"

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
        if diskReadsForceDisabledInProcess {
            return true
        }
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
    ///
    /// Retries a small, strictly bounded number of times (never an
    /// unbounded/blocking loop — a review finding specifically flagged
    /// unbounded retry workers as their own hazard): a transient write
    /// failure (e.g. a momentary `ENOSPC` freed up moments later by a
    /// concurrent eviction) may genuinely succeed on a second attempt,
    /// since each attempt is a plain synchronous syscall already
    /// performed inside this held exclusive lock, not a separate blocking
    /// wait that could itself accumulate workers. If every attempt still
    /// fails, this marker's own durability cannot be established at
    /// all — the last remaining fallback, ``diskReadsForceDisabledInProcess``,
    /// closes the review's exact "if commit impossible ... permanently
    /// fail-close disk reads in-process" requirement for the one case
    /// nothing durable can protect: this *process* still refuses to serve
    /// anything for the rest of its own lifetime, even though a
    /// completely fresh process (after an eventual restart, once
    /// whatever disk condition caused every attempt above to fail has
    /// cleared) cannot itself inherit that in-memory-only protection.
    @discardableResult
    func markDiskReadsDisabledLocked() -> Bool {
        let name = Self.diskReadsDisabledMarkerName
        let tempName = name + ".tmp"
        for _ in 0 ..< 3 {
            guard (try? secureDirectory.writeTempAndFsync(tempName: tempName, data: Data())) != nil
            else { continue }
            guard
                (try? secureDirectory.renameAndFsyncDirectory(from: tempName, to: name)) != nil
            else { continue }
            return true
        }
        diskReadsForceDisabledInProcess = true
        return false
    }

    /// `true` if this whole cache's disk writes are currently disabled —
    /// see ``markDiskWritesDisabledLocked()``. Checked by
    /// ``AssetDiskCache/requireDiskWritesEnabledLocked()`` before any new
    /// payload/metadata write is allowed to proceed.
    func areDiskWritesDisabledLocked() -> Bool {
        do {
            return try secureDirectory.attributes(name: Self.diskWritesDisabledMarkerName) != nil
        } catch {
            // Same fail-closed reasoning as ``areDiskReadsDisabled()``: an
            // inability to even check for this marker must never be
            // treated as "writes are enabled" — this marker exists
            // specifically to force the fail-closed path when this
            // cache's on-disk budget cannot otherwise be trusted.
            return true
        }
    }

    /// Best-effort marks the entire cache's disk *writes* as disabled:
    /// the fail-closed fallback for when ``evictIfNeeded()`` cannot
    /// durably confirm this cache's total physical on-disk usage is
    /// within budget (an unenumerable directory listing, an unreadable
    /// stray-file size, or a post-eviction total that still exceeds the
    /// high water mark). Must be called from inside an already-held
    /// ``SecureCacheDirectory/withExclusiveLock(_:)`` critical section,
    /// exactly like ``markDiskReadsDisabledLocked()``.
    func markDiskWritesDisabledLocked() {
        let name = Self.diskWritesDisabledMarkerName
        _ = try? secureDirectory.writeTempAndFsync(tempName: name + ".tmp", data: Data())
        _ = try? secureDirectory.renameAndFsyncDirectory(from: name + ".tmp", to: name)
    }

    /// Best-effort clears the whole-cache disk-writes-disabled marker —
    /// called only once ``evictIfNeeded()`` has itself just durably
    /// confirmed accounted physical usage is within budget again (the one
    /// event that counts as this cache's own "locked recovery proves
    /// budget" contract). Must be called from inside an already-held
    /// lock, exactly like ``markDiskWritesDisabledLocked()``.
    func clearDiskWritesDisabledLocked() {
        _ = try? secureDirectory.remove(name: Self.diskWritesDisabledMarkerName)
        try? secureDirectory.fsyncRootDirectory()
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

    /// Durably protects `keyHash` after some other operation could not
    /// otherwise confirm it was safe to leave unprotected — the single
    /// entry point ``AssetDiskCache/Removal/remove(_:token:)`` uses for
    /// both of its own ``persistTombstoneLocked(keyHash:fenceGeneration:)``
    /// call sites, so this exact "retry, then escalate" fallback sequence
    /// only needs to be written and reasoned about once.
    ///
    /// Retries the tombstone write itself a small, strictly bounded
    /// number of times before falling back to
    /// ``markDiskReadsDisabledLocked()`` (which itself retries, then
    /// falls back to ``diskReadsForceDisabledInProcess`` as an absolute
    /// last resort) — never an unbounded loop, matching
    /// ``markDiskReadsDisabledLocked()``'s own bound. This closes the
    /// review's "double `try?` failure" gap: previously, a single failed
    /// attempt at *each* of the tombstone write and the disabled-marker
    /// fallback write left this key with no durable protection at all
    /// and no in-process fallback either, silently risking a stale
    /// resurrection of exactly the bytes this call exists to invalidate.
    /// Must be called from inside an already-held exclusive lock, exactly
    /// like ``persistTombstoneLocked(keyHash:fenceGeneration:)``.
    func protectKeyAfterFailedDeletionLocked(keyHash: String, fenceGeneration: Int) {
        for _ in 0 ..< 3 where (try? persistTombstoneLocked(
            keyHash: keyHash,
            fenceGeneration: fenceGeneration
        )) != nil {
            return
        }
        markDiskReadsDisabledLocked()
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
