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

    /// A dedicated, unbounded-growth GCD queue used only to host the
    /// blocking `flock(2)` *acquire* wait below, kept entirely off Swift
    /// concurrency's fixed-size cooperative thread pool.
    ///
    /// `LOCK_EX` blocks for as long as another holder keeps the lock —
    /// potentially the full duration of that holder's own critical
    /// section. Every caller of this lock is an actor-isolated method, so
    /// calling `flock(LOCK_EX)` directly from that method's own execution
    /// would occupy one of Swift's limited cooperative-pool worker threads
    /// for the entire wait. On a host with few cores (few pool threads)
    /// and enough concurrent contention for this same lock, every pool
    /// thread can end up parked inside that blocking wait simultaneously —
    /// including threads waiting on a holder task that itself can never be
    /// *scheduled* because no pool thread is free to run it, deadlocking
    /// the whole process rather than merely serializing it. GCD's global
    /// concurrent queues are, by design, independent of and can grow
    /// beyond that fixed pool specifically to accommodate blocked work
    /// like this, so contention here can never starve Swift's task
    /// scheduler.
    private static let lockAcquireQueue = DispatchQueue.global(qos: .utility)

    /// Opens (creating if needed), verifies, and acquires an exclusive
    /// `flock(2)` hold on this cache's dedicated lock file — the one
    /// primitive in this type that serializes callers against every other
    /// concurrent caller *in this process or any other process* pointed at
    /// the same cache directory, since actor isolation alone only
    /// serializes calls made through one specific `AssetDiskCache`
    /// *instance*. Returns the held, verified file descriptor; the caller
    /// owns it and must release it via ``releaseExclusiveLock(_:)``.
    ///
    /// Only the genuinely unbounded step — the `LOCK_EX` acquire wait — is
    /// offloaded to ``lockAcquireQueue``; opening and verifying the lock
    /// file happen directly on the caller's own executor first, exactly as
    /// before. **Every actor-isolated caller must call this as its own
    /// direct `await`, immediately followed by its synchronous critical
    /// section and a `defer`-scheduled ``releaseExclusiveLock(_:)`` —
    /// never route the returned descriptor, or the critical section that
    /// uses it, through a closure passed into some *other* type's async
    /// function.** Swift only guarantees an actor-isolated method resumes
    /// back on that actor's own executor after *that method's own* await
    /// point; a closure handed to a plain (non-actor) async function like
    /// this one has no such guarantee once its continuation is resumed
    /// from an arbitrary thread (here, ``lockAcquireQueue``), so running
    /// actor-isolated work from inside such a closure would silently touch
    /// actor state off its own executor.
    ///
    /// `flock` calls interrupted by a signal (`EINTR`) are retried rather
    /// than surfaced as a spurious failure, matching this type's existing
    /// `read`/`write` retry convention.
    func acquireExclusiveLock() async throws -> Int32 {
        let lockFD = openat(
            rootFD, Self.lockFileName, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600
        )
        guard lockFD >= 0 else {
            throw AssetError.cachePersistenceFailed(
                "Could not open cache lock file (errno \(errno))"
            )
        }
        do {
            // `O_NOFOLLOW` alone only refuses a *symlink* planted at this
            // name; it does not rule out the lock name having been
            // replaced with a FIFO, device node, or other non-regular-file
            // type (which still opens successfully, but can make `flock`
            // behave unpredictably or block forever on some special file
            // types), nor an external hardlink to another user's file on a
            // shared filesystem. Reuse the exact same verification every
            // other entry this cache reads/writes already requires —
            // regular file, same owner, same device as the verified root,
            // exactly one hardlink — before ever calling `flock` on it.
            try requireVerifiedRegularFile(descriptor: lockFD, name: Self.lockFileName)
            try await Self.blockingAcquire(lockFD)
        } catch {
            close(lockFD)
            throw error
        }
        return lockFD
    }

    /// Releases and closes a descriptor obtained from
    /// ``acquireExclusiveLock()``. `LOCK_UN` is documented as never
    /// blocking, so this stays a plain synchronous call — safe to invoke
    /// directly from a `defer` on the caller's own executor.
    func releaseExclusiveLock(_ lockFD: Int32) {
        flock(lockFD, LOCK_UN)
        close(lockFD)
    }

    /// Convenience wrapper for callers whose critical section does not
    /// touch actor-isolated state (for example a plain, self-contained
    /// test body): acquires, runs `body`, and always releases (even if
    /// `body` throws). **Not** used by any `AssetDiskCache` production
    /// call site — see ``acquireExclusiveLock()``'s doc comment for why.
    func withExclusiveLock<T>(_ body: () throws -> T) async throws -> T {
        let lockFD = try await acquireExclusiveLock()
        defer { releaseExclusiveLock(lockFD) }
        return try body()
    }

    /// Performs the blocking `flock(lockFD, LOCK_EX)` acquire wait on
    /// ``lockAcquireQueue`` rather than the calling task's own executor.
    /// `lockFD` is a plain, `Sendable` file-descriptor integer, still owned
    /// (and closed) by the caller; this only ever reads/waits on it.
    private static func blockingAcquire(_ lockFD: Int32) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lockAcquireQueue.async {
                while true {
                    if flock(lockFD, LOCK_EX) == 0 {
                        continuation.resume()
                        return
                    }
                    if errno == EINTR {
                        continue
                    }
                    continuation.resume(
                        throwing: AssetError.cachePersistenceFailed(
                            "flock failed to acquire (errno \(errno))"
                        )
                    )
                    return
                }
            }
        }
    }
}
