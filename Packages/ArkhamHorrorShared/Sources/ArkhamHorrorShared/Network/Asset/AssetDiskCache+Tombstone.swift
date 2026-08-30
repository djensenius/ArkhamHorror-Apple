import Foundation

/// The whole-cache disk-*writes*-disabled marker for ``AssetDiskCache``,
/// split out of `AssetDiskCache.swift` purely to stay under this
/// package's `file_length` convention, the same way
/// `AssetDiskCache+Recovery.swift` and `AssetDiskCache+Read.swift` already
/// are.
///
/// This cache does not maintain a durable, cross-process per-key
/// tombstone or a durable "disk reads disabled" marker: neither is
/// required for correctness now that every disk-only hit — regardless of
/// whether an earlier deletion for it fully succeeded, in this process or
/// any other sharing the same directory — must independently pass a
/// fresh, online conditional (`ETag`/`Last-Modified`) revalidation against
/// the live server before ``AssetCacheService/asset(for:)``/
/// ``AssetCacheService/revalidate(for:)`` will ever trust, cache, or
/// return it (see ``AssetDiskCache``'s own doc comment, and
/// ``AssetCacheService/tombstonedKeys`` — the in-process-only, best-effort
/// mirror of a failed deletion that remains sufficient for *this*
/// process's own lifetime). A failed metadata-pointer deletion at worst
/// leaves structurally-valid-looking bytes physically present on disk
/// that this cache's own next successful read can still discover — but
/// any read of them is always, unconditionally, revalidated online before
/// ever being served, so a stale local disk state can never resurrect
/// content the origin itself considers gone or changed.
///
/// The disk *writes*-disabled marker is a distinct concern (this cache's
/// own physical on-disk *budget*, not read trust) and remains fully
/// durable — see ``markDiskWritesDisabledLocked()``.
extension AssetDiskCache {
    /// The single, fixed-name, whole-cache "fail closed for writes"
    /// marker: present only when ``evictIfNeeded()`` could not durably
    /// confirm this cache's *total physical on-disk usage* is within
    /// ``AssetCacheLimits/highWaterMarkDiskBytes`` — either because the
    /// directory could not even be enumerated/accounted for, or because a
    /// full eviction pass still could not bring accounted usage back
    /// under budget (e.g. persistent removal failures). See
    /// ``AssetDiskCache/requireDiskWritesEnabledLocked()``.
    static let diskWritesDisabledMarkerName = ".disk-writes-disabled"

    /// `true` if this whole cache's disk writes are currently disabled —
    /// see ``markDiskWritesDisabledLocked()``. Checked by
    /// ``AssetDiskCache/requireDiskWritesEnabledLocked()`` before any new
    /// payload/metadata write is allowed to proceed.
    func areDiskWritesDisabledLocked() -> Bool {
        do {
            return try secureDirectory.attributes(name: Self.diskWritesDisabledMarkerName) != nil
        } catch {
            // Same fail-closed reasoning as every other durable-marker
            // check in this cache: an inability to even check for this
            // marker must never be treated as "writes are enabled" — this
            // marker exists specifically to force the fail-closed path
            // when this cache's on-disk budget cannot otherwise be
            // trusted.
            return true
        }
    }

    /// Best-effort marks the entire cache's disk *writes* as disabled:
    /// the fail-closed fallback for when ``evictIfNeeded()`` cannot
    /// durably confirm this cache's total physical on-disk usage is
    /// within budget (an unenumerable directory listing, an unreadable
    /// stray-file size, or a post-eviction total that still exceeds the
    /// high water mark). Must be called from inside an already-held
    /// ``SecureCacheDirectory/withExclusiveLock(_:)`` critical section.
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
}
