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

    /// Opens (creating and verifying if needed), and acquires an
    /// exclusive `flock(2)` hold on this cache's dedicated lock file — the
    /// one primitive in this type that serializes callers against every
    /// other concurrent caller *in this process or any other process*
    /// pointed at the same cache directory, since actor isolation alone
    /// only serializes calls made through one specific `AssetDiskCache`
    /// *instance*. Returns the held, verified file descriptor; the caller
    /// owns it and must release it via ``releaseExclusiveLock(_:)``.
    ///
    /// Every call funnels through ``lockCoordinator``, which owns the one
    /// lock file descriptor this instance will ever open (opened once, on
    /// first use, and reused for this instance's entire lifetime) and
    /// serializes every in-process caller through its own FIFO queue, so
    /// that regardless of how many `Task`s concurrently call this method,
    /// at most one of them is ever actually polling the real `flock` (see
    /// ``SecureCacheDirectoryLockCoordinator``'s own doc comment for why
    /// this matters and how it is enforced). **Every actor-isolated
    /// caller must call this as its own direct `await`, immediately
    /// followed by its synchronous critical section and a
    /// `defer`-scheduled ``releaseExclusiveLock(_:)`` — never route the
    /// returned descriptor, or the critical section that uses it, through
    /// a closure passed into some *other* type's async function.** Swift
    /// only guarantees an actor-isolated method resumes back on that
    /// actor's own executor after *that method's own* await point; a
    /// closure handed to a plain (non-actor) async function like this one
    /// has no such guarantee once its continuation is resumed from an
    /// arbitrary thread, so running actor-isolated work from inside such a
    /// closure would silently touch actor state off its own executor.
    ///
    /// `flock` calls interrupted by a signal (`EINTR`) are retried rather
    /// than surfaced as a spurious failure, matching this type's existing
    /// `read`/`write` retry convention.
    func acquireExclusiveLock() async throws -> Int32 {
        try await lockCoordinator.acquire(rootFD: rootFD) { [weak self] descriptor in
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
            //
            // `self` cannot actually be nil here in practice: an async
            // instance method's own stack frame keeps `self` alive for
            // its entire execution, including every suspension, and this
            // closure only ever runs synchronously from inside that
            // still-executing call. `weak` is captured purely so this
            // closure cannot itself extend that lifetime, never as a
            // genuinely expected runtime case — but a security-critical
            // verification gate must never silently *succeed* (skip
            // `flock` verification and let the caller proceed to lock an
            // unverified file) merely because some future refactor makes
            // this theoretical case reachable. Fail closed instead.
            guard let self else {
                throw AssetError.cachePersistenceFailed(
                    "SecureCacheDirectory was deallocated before lock-file verification could run"
                )
            }
            try requireVerifiedRegularFile(descriptor: descriptor, name: Self.lockFileName)
        }
    }

    /// Releases the `flock` hold obtained from ``acquireExclusiveLock()``
    /// (never closing the shared descriptor -- ``lockCoordinator`` reuses
    /// it for this instance's entire lifetime) and, if another in-process
    /// caller is queued waiting, hands it local ownership. `lockFD` is
    /// accepted (and ignored beyond a sanity check) purely to keep this
    /// method's call sites -- written against the descriptor
    /// ``acquireExclusiveLock()`` returned -- unchanged; the coordinator
    /// already knows its own single descriptor internally.
    func releaseExclusiveLock(_ lockFD: Int32) {
        lockCoordinator.release(expectedFD: lockFD)
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
}
