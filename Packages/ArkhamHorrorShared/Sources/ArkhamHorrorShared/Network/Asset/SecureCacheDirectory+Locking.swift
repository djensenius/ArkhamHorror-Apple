import Darwin
import Foundation

/// Cross-instance/cross-process advisory locking for `SecureCacheDirectory`,
/// split out of `SecureCacheDirectory.swift` purely to stay under this
/// package's `file_length` convention.
extension SecureCacheDirectory {
    /// The fixed leaf name of this cache's cross-process/cross-instance
    /// advisory lock file, inside the verified root directory. Not
    /// `private`: ``AssetDiskCache/removeAll()`` must recognize and skip
    /// this exact name in its own directory listing — unlinking the lock
    /// file out from under a held `flock` would silently detach every
    /// future `openat` of this name onto a *different* underlying inode,
    /// letting a subsequent caller's lock stop contending with any
    /// concurrent holder still referencing the old (now-unlinked) file.
    static let lockFileName = ".arkham-cache.lock"

    /// Serializes `body` against every other concurrent caller — in this
    /// process *or any other process* — that also calls this method
    /// against the exact same cache directory, using `flock(2)` on a
    /// dedicated lock file held inside the verified root directory.
    ///
    /// Actor isolation alone only serializes calls made through one
    /// specific `AssetDiskCache` *instance*: two separate instances (in
    /// the same process, e.g. two app scenes, or in genuinely separate
    /// processes/app extensions sharing one on-disk cache directory) each
    /// have their own independent actor and so are not serialized against
    /// each other by Swift concurrency at all. `flock` is associated with
    /// the *open file description*, not the calling process or Swift
    /// actor, so every independent `openat` of this exact lock file — from
    /// any instance, any process — contends for the same, genuinely
    /// exclusive lock; only one holder's `body` ever runs at a time
    /// system-wide for this cache directory. This is the only primitive
    /// in this type that provides synchronization beyond a single opened
    /// root descriptor's own in-process operations, and every entry
    /// mutation (`set`/`touch`/`remove`/`removeAll`/orphan recovery) that
    /// must not interleave with another instance's own mutation of the
    /// same entry names is expected to run its whole critical section
    /// inside this call.
    ///
    /// A `LOCK_EX` request blocks (rather than failing immediately) until
    /// the lock is acquired; `flock` calls interrupted by a signal
    /// (`EINTR`) are retried rather than surfaced as a spurious failure,
    /// matching this type's existing `read`/`write` retry convention. The
    /// lock is always released (even if `body` throws) before this
    /// returns/rethrows.
    func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let lockFD = openat(
            rootFD, Self.lockFileName, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600
        )
        guard lockFD >= 0 else {
            throw AssetError.cachePersistenceFailed(
                "Could not open cache lock file (errno \(errno))"
            )
        }
        defer { close(lockFD) }
        while true {
            if flock(lockFD, LOCK_EX) == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw AssetError.cachePersistenceFailed("flock failed to acquire (errno \(errno))")
        }
        defer { flock(lockFD, LOCK_UN) }
        return try body()
    }
}
