import Darwin
import Foundation

/// A verified, descriptor-relative view onto a single cache root directory,
/// used by ``AssetDiskCache`` for every entry (payload/metadata/temp file)
/// operation instead of `FileManager`'s path-string APIs.
///
/// `FileManager`'s path-based APIs (`Data(contentsOf:)`,
/// `attributesOfItem(atPath:)`, `moveItem`/`replaceItemAt`) all resolve
/// every path component fresh, on every call, including any symlink an
/// attacker (or a confused prior process) may have planted at the leaf
/// entry name itself, or by replacing the cache root directory in the
/// filesystem namespace between this cache's `init` and a later call. This
/// type instead opens the cache root directory exactly once, at `init`,
/// and holds that descriptor for its entire lifetime: every subsequent
/// operation is descriptor-relative (`openat`/`fstatat`/`renameat`/
/// `unlinkat`, all Darwin/POSIX primitives available identically across
/// this package's four deployment platforms), so it keeps operating on the
/// exact directory verified at `init` even if the original path is later
/// deleted, replaced, or symlinked elsewhere — this type never re-resolves
/// that absolute path again. Every leaf entry is additionally opened with
/// `O_NOFOLLOW`, which fails closed (`ELOOP`) rather than silently
/// following a symlink planted at that exact name, and every opened
/// descriptor is `fstat`-checked to be a regular file owned by the same
/// user as the root directory itself before its contents are ever trusted.
final class SecureCacheDirectory: @unchecked Sendable {
    /// The maximum number of bytes ever read for a metadata sidecar. Real
    /// sidecars are a few hundred bytes of JSON (a handful of short
    /// strings, hashes, and integers); this bound is generous headroom
    /// while still being small enough that no metadata read can be used
    /// to force a large allocation — payload reads are bounded separately,
    /// by the caller-supplied, much larger ``AssetCacheLimits/maxEncodedBytes``.
    static let maxMetadataBytes = 16384

    let rootFD: Int32
    private let rootOwnerUID: uid_t
    /// The root directory's own device number, recorded at `init` and
    /// required (alongside a regular-file/link-count check) of every leaf
    /// entry this type ever reads or writes — see
    /// ``requireVerifiedRegularFile(descriptor:name:)``. A bind mount, a
    /// different volume mounted at a name inside the cache root, or any
    /// other cross-device substitution planted at an entry name changes
    /// `st_dev`, so it can never silently pass as this cache's own data
    /// even though `O_NOFOLLOW` alone would not by itself distinguish it
    /// from a same-device file.
    private let rootDevice: dev_t
    /// Whether *this exact instance's own* call to
    /// ``SecureCacheDirectory/openOrCreateVerifiedDirectory(at:)`` won the
    /// race to create the cache root directory itself (`true`), as opposed
    /// to the root directory already existing beforehand for any reason,
    /// including a concurrent creator elsewhere winning that same race
    /// instead (`false`). This is the only race-proof, un-spoofable
    /// evidence available anywhere in this cache that a root directory is
    /// genuinely, provably fresh — no combination of directory-listing or
    /// survivor-name checks performed *after* the fact can ever
    /// distinguish "created by me, just now" from "already existed, and
    /// every file inside it just happens to look tolerable". It is
    /// consulted exactly once, in
    /// ``ensureRootAuthorityInitializedLockedUnwrapped(isSurvivingEntryAcceptable:)``,
    /// as one of the two independent proofs of freshness (the other being
    /// the durable, cross-process/cross-instance ``rootFreshnessWitnessFileName``
    /// file this same flag also causes `init` to best-effort persist,
    /// below) that gate ever treating an absent clear epoch as "pristine,
    /// safe to initialize at zero" rather than "used root with lost
    /// authority state, must fail closed".
    let rootDirectoryWasFreshlyCreated: Bool
    /// `true` once this exact instance has, at any point in its own
    /// lifetime, durably confirmed this root's authority (the clear-epoch
    /// counter and its root-init marker) to genuinely already exist —
    /// set exactly once, from inside
    /// ``ensureRootAuthorityInitializedLockedUnwrapped(isSurvivingEntryAcceptable:)``,
    /// on every successful return from either of its two "authority
    /// already exists" outcomes. Never cleared afterward.
    ///
    /// Closes a residual, same-instance-only window
    /// ``rootFreshnessWitnessFileName``'s own durable one-shot consumption
    /// (see `SecureCacheDirectory+ClearEpoch.swift`'s type-level doc
    /// comment) cannot close alone: ``rootDirectoryWasFreshlyCreated``
    /// above is a `let`, fixed at `init` and never updated, so it stays
    /// `true` for this instance's entire lifetime regardless of what
    /// later happens to this root's durable files. Without this mutable
    /// latch, a long-lived instance that already durably observed real
    /// authority once could, if this root's durable counter, marker,
    /// *and* witness were all later lost externally, still fall back to
    /// its own stale `rootDirectoryWasFreshlyCreated == true` and wrongly
    /// re-initialize a used root's authority back to epoch `0`. Once this
    /// latch is `true`, the "both missing" branch fails closed
    /// unconditionally, never consulting `rootDirectoryWasFreshlyCreated`
    /// or any witness at all.
    ///
    /// Guarded by the same cross-process ``acquireExclusiveLock()`` every
    /// other read/write of this root's durable authority already
    /// requires — only ever touched from inside
    /// `ensureRootAuthorityInitializedLockedUnwrapped(isSurvivingEntryAcceptable:)`,
    /// which every call site holds the lock across.
    var hasDurablyObservedRootAuthorityOnce = false
    /// This instance's single, in-process lock coordinator — see
    /// ``SecureCacheDirectoryLockCoordinator``'s own doc comment. Opens
    /// its lock file descriptor lazily (on first
    /// ``acquireExclusiveLock()`` call), reuses it for this instance's
    /// entire lifetime, and closes it in its own `deinit`.
    let lockCoordinator = SecureCacheDirectoryLockCoordinator()
    let faultState = FaultInjectionState()

    /// Opens and verifies `directory` exactly once. Throws
    /// ``AssetError/cachePersistenceFailed(_:)`` if `directory` cannot be
    /// opened as a directory (including if it is itself a symlink: opened
    /// with `O_NOFOLLOW`) or if creating it first fails.
    ///
    /// Every path component from the filesystem root down to `directory`
    /// itself is walked with its own `openat`/`mkdirat` call chained off
    /// the previous component's own already-opened, `O_NOFOLLOW`-verified
    /// descriptor (see ``Self/openVerifiedComponent(parentFD:name:createIfMissing:)``)
    /// — never `FileManager.createDirectory(at:withIntermediateDirectories:)`,
    /// which re-resolves the whole path string component-by-component on
    /// every call and, since it never passes `O_NOFOLLOW` anywhere, would
    /// silently follow a symlink an attacker (or a confused prior process)
    /// planted at *any* intermediate component — not just the final leaf —
    /// transparently redirecting where this cache's data is actually read
    /// from and written to.
    ///
    /// `fileManager` is intentionally unused: kept only so every existing
    /// call site (production and test) stays source-compatible without
    /// this type ever again touching a `FileManager` path-string API for
    /// directory creation.
    init(directory: URL, fileManager _: FileManager) throws {
        let walkResult = try Self.openOrCreateVerifiedDirectory(at: directory)
        let descriptor = walkResult.descriptor
        var rootStat = stat()
        guard fstat(descriptor, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            close(descriptor)
            throw AssetError.cachePersistenceFailed("Cache root is not a verified directory")
        }
        // Every ancestor up to and including this leaf directory already
        // passed ``SecureCacheDirectory/requireTrustedAncestor(info:name:trustedOwnerUID:)``'s
        // "root or this process's own uid" policy during the walk above
        // (see `SecureCacheDirectory+PathWalk.swift`), tolerating a
        // pre-existing, OS-managed ancestor this cache does not itself
        // own. But the leaf *is* this cache's own directory -- the one
        // thing it fully controls the creation of -- so it alone is held
        // to the stricter policy of never legitimately being root-owned.
        guard rootStat.st_uid == getuid() else {
            close(descriptor)
            throw AssetError.cachePersistenceFailed("Cache root has an unexpected owner")
        }
        rootFD = descriptor
        rootOwnerUID = rootStat.st_uid
        rootDevice = rootStat.st_dev
        rootDirectoryWasFreshlyCreated = walkResult.leafWasFreshlyCreated
        // Deliberately does *not* initialize the durable clear-epoch
        // counter (or its root-init marker) here: doing so race-free
        // requires this directory's cross-process
        // ``acquireExclusiveLock()``, which is `async` and unavailable
        // from this synchronous, throwing `init`. See
        // ``ensureRootAuthorityInitializedLocked()`` in
        // `SecureCacheDirectory+ClearEpoch.swift` for where that
        // durable, cross-process-locked transaction actually happens —
        // called by every ``AssetDiskCache`` locked entry point, exactly
        // once per instance, strictly before that entry point's own
        // first read of the durable epoch.
        //
        // If this exact call just won the race to create the root
        // directory, best-effort (unlocked) persist the durable freshness
        // witness right now, purely as an optimization: it lets *other*
        // instances/processes that open this same, now-no-longer-empty
        // root later see durable proof of freshness even after this
        // instance's own in-memory `rootDirectoryWasFreshlyCreated` flag
        // is gone. A failure here is never a correctness problem -- this
        // exact instance's own in-memory flag remains fully sufficient
        // proof for its own lifetime, and
        // ``ensureRootAuthorityInitializedLockedUnwrapped(isSurvivingEntryAcceptable:)``
        // durably retries this same write, under its own cross-process
        // lock, the very first time this instance performs any locked
        // operation -- so a transient failure here is fully recovered
        // moments later without this directory's own fail-closed
        // freshness contract ever being weakened for any other
        // instance/process. This write is safe unlocked specifically
        // because `mkdirat`'s own atomicity already proved this call is
        // the sole, exclusive first creator: no other opener of this
        // exact path could concurrently believe itself to also be the
        // fresh creator, so nothing else could be racing to write this
        // witness at the same time.
        if rootDirectoryWasFreshlyCreated {
            _ = try? installRootFreshnessWitnessBestEffort()
        }
    }

    deinit {
        close(rootFD)
    }

    /// Reads `name` bounded by `maxBytes`, requiring the opened descriptor
    /// to resolve (without following a symlink) to a regular file owned by
    /// the same user as the verified root directory, and whose size does
    /// not exceed `maxBytes`. Returns `nil` for a clean "does not exist"
    /// miss; throws for any other failure (wrong type, wrong owner, over
    /// bound, short read).
    func read(name: String, maxBytes: Int) throws -> Data? {
        let descriptor = openat(rootFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw AssetError.cachePersistenceFailed("Could not open '\(name)' (errno \(errno))")
        }
        defer { close(descriptor) }
        try requireVerifiedRegularFile(descriptor: descriptor, name: name)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw AssetError.cachePersistenceFailed("fstat failed for '\(name)'")
        }
        guard info.st_size >= 0, info.st_size <= maxBytes else {
            throw AssetError.cachePersistenceFailed("'\(name)' exceeds the bounded read size")
        }
        let expected = Int(info.st_size)
        guard expected > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: expected)
        var totalRead = 0
        while totalRead < expected {
            let readCount = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base + totalRead, expected - totalRead)
            }
            if readCount < 0 {
                // A `read()` interrupted by a signal (`EINTR`) is not a
                // genuine failure and must be retried rather than
                // surfaced as a spurious cache-read error; any other
                // negative result is a real failure, reported with its
                // errno for diagnosability.
                if errno == EINTR {
                    continue
                }
                throw AssetError.cachePersistenceFailed(
                    "read failed for '\(name)' (errno \(errno))"
                )
            }
            guard readCount > 0 else {
                throw AssetError.cachePersistenceFailed("Short read for '\(name)'")
            }
            totalRead += readCount
        }
        return Data(buffer)
    }

    /// The exact on-disk size and regular-file/ownership verification for
    /// `name`, without reading its contents. Returns `nil` for a clean
    /// miss. Applies the identical regular-file/owner/device/link-count
    /// policy ``requireVerifiedRegularFile(descriptor:name:)`` enforces
    /// for an opened descriptor -- a hardlinked file sharing another
    /// entry's inode, or one substituted from a different device/volume
    /// at this exact name, must never be treated as "this cache's own
    /// verified regular file" merely because it happens to answer `stat`
    /// as one; both entry points share the same underlying check so
    /// neither can silently drift from the other.
    func attributes(name: String) throws -> (size: Int, isRegularFile: Bool)? {
        if faultState.shouldFailAttributes(name: name) {
            throw AssetError.cachePersistenceFailed("injected fault: attributes('\(name)')")
        }
        var info = stat()
        guard fstatat(rootFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw AssetError.cachePersistenceFailed("fstatat failed for '\(name)' (errno \(errno))")
        }
        let isRegular = isVerifiedRegularFile(info: info)
        return (size: Int(info.st_size), isRegularFile: isRegular)
    }

    /// Lists every entry name directly inside the verified root directory,
    /// via a `fdopendir` over a `dup`'d copy of the held root descriptor
    /// (so the directory stream's own internal cursor state can never
    /// disturb the root descriptor this type reuses for every other call).
    func listNames() throws -> [String] {
        try faultState.recordListNamesCallAndCheckFault()
        let duped = dup(rootFD)
        guard duped >= 0, let stream = fdopendir(duped) else {
            if duped >= 0 {
                close(duped)
            }
            throw AssetError.cachePersistenceFailed("Could not list cache root directory")
        }
        defer { closedir(stream) }
        // `dup(rootFD)` shares its *file offset* with `rootFD` itself (POSIX
        // dup semantics: duplicated descriptors share the same open file
        // description, including the directory read position) — so
        // without an explicit `rewinddir`, a *second* call to this method
        // would silently resume (in practice, immediately hit EOF) from
        // wherever the *previous* call's `readdir` loop left the shared
        // position, rather than re-listing from the start. `rewinddir`
        // seeks the underlying descriptor back to the beginning before
        // this call ever reads an entry, making every call see the
        // directory's *current* full contents regardless of how many
        // prior calls (via other `dup`'d descriptors of this exact same
        // open file description) already read through it.
        rewinddir(stream)
        var names: [String] = []
        // `readdir` returns `NULL` both at genuine end-of-directory *and*
        // on error (for example an I/O error partway through a large
        // directory, or the underlying descriptor being invalidated by a
        // concurrent removal of the directory itself) -- the two are
        // indistinguishable from the return value alone. POSIX's
        // documented way to tell them apart is to clear `errno` to `0`
        // immediately before *each* call and check it again immediately
        // after a `NULL` return: a still-zero `errno` confirms a clean
        // end-of-directory, while any nonzero value means this call
        // stopped partway through and the entries seen so far are
        // incomplete. Without this check, a partial enumeration (for
        // example after some fixed number of names) would silently look
        // identical to a short, fully-listed directory -- letting
        // `removeAll()` believe every survivor had been enumerated and
        // proceed to clear tombstones/disabled markers while entries this
        // call never saw are still physically present on disk.
        while true {
            if faultState.shouldFailReaddirAfterEntryCount(currentCount: names.count) {
                throw AssetError.cachePersistenceFailed(
                    "injected fault: readdir failed partway through listing cache root"
                )
            }
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 {
                    throw AssetError.cachePersistenceFailed(
                        "readdir failed partway through listing cache root (errno \(errno))"
                    )
                }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { rawBuffer -> String in
                let pointer = rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self)
                return String(cString: pointer)
            }
            guard name != ".", name != ".." else { continue }
            names.append(name)
        }
        return names
    }

    /// The shared regular-file/owner/device/link-count predicate behind
    /// both ``attributes(name:)`` and ``requireVerifiedRegularFile(descriptor:name:)``
    /// -- see that method's doc comment for why every one of these four
    /// checks matters.
    private func isVerifiedRegularFile(info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == rootOwnerUID
            && info.st_dev == rootDevice
            && info.st_nlink == 1
    }

    /// Verifies an already-opened descriptor resolves to a regular file
    /// owned by the same user as the verified root directory, on the same
    /// device as that root, and with exactly one hardlink — never
    /// trusting `name` alone, since a symlink refused by `O_NOFOLLOW`
    /// already fails at `open`/`openat` time, but a *hardlinked* regular
    /// file swapped in by another user (or process) on a shared
    /// filesystem, or a different volume/bind-mount substituted at this
    /// exact entry name, would still open successfully and must be
    /// rejected here instead. `st_nlink == 1` specifically rules out an
    /// external hardlink sharing this same inode: every entry this cache
    /// itself ever creates is written fresh via `O_CREAT | O_EXCL` (see
    /// ``writeTempAndFsync(tempName:data:)``) and only ever renamed, never
    /// linked, so a legitimate cache-owned file can never have a link
    /// count greater than one.
    func requireVerifiedRegularFile(descriptor: Int32, name: String) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw AssetError.cachePersistenceFailed("fstat failed for '\(name)'")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw AssetError.cachePersistenceFailed("'\(name)' is not a regular file")
        }
        guard info.st_uid == rootOwnerUID else {
            throw AssetError.cachePersistenceFailed("'\(name)' has an unexpected owner")
        }
        guard info.st_dev == rootDevice else {
            throw AssetError.cachePersistenceFailed("'\(name)' is not on the cache root's device")
        }
        guard info.st_nlink == 1 else {
            throw AssetError.cachePersistenceFailed("'\(name)' has an unexpected hardlink count")
        }
    }
}
