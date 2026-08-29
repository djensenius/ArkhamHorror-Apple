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

    private let rootFD: Int32
    private let rootOwnerUID: uid_t
    private let faultState = FaultInjectionState()

    /// Test-only deterministic fault injection, installed via `@testable
    /// import`. Replaces `FailingFileManager` (a `FileManager` subclass)
    /// now that this type performs its own POSIX I/O directly rather than
    /// routing writes/renames/listings through `FileManager` at all — a
    /// fake `FileManager` subclass can no longer intercept anything.
    /// `failSuffixes`/`failPrefixes` match the *final* (non-`.tmp`) target
    /// name of a temp-file write, mirroring a real interrupted write: a
    /// truncated stub left at the temp name, then a thrown error, so a
    /// test can assert on production code's cleanup of that leftover
    /// file. `listNamesFailuresRemaining` fails that many subsequent
    /// `listNames()` calls before succeeding normally again.
    /// `failRemoveSuffixes`/`failRemovePrefixes` independently fail
    /// `remove(name:)` for any matching name (e.g. an unremovable entry
    /// during a real `removeAll()`), without affecting temp-file writes.
    func installFaultInjection(
        failSuffixes: Set<String> = [],
        failPrefixes: Set<String> = [],
        failRemoveSuffixes: Set<String> = [],
        failRemovePrefixes: Set<String> = [],
        listNamesFailuresRemaining: Int = 0
    ) {
        faultState.failSuffixes = failSuffixes
        faultState.failPrefixes = failPrefixes
        faultState.failRemoveSuffixes = failRemoveSuffixes
        faultState.failRemovePrefixes = failRemovePrefixes
        faultState.listNamesFailuresRemaining = listNamesFailuresRemaining
    }

    /// Test-only. The number of times `listNames()` has actually been
    /// called (successful or failed), for asserting a call was — or, more
    /// often, was deliberately *not* — made after crossing an actor
    /// boundary.
    var listNamesCallCount: Int {
        faultState.listNamesCallCount
    }

    /// Opens and verifies `directory` exactly once. Throws
    /// ``AssetError/cachePersistenceFailed(_:)`` if `directory` cannot be
    /// opened as a directory (including if it is itself a symlink: opened
    /// with `O_NOFOLLOW`) or if creating it first fails.
    init(directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = directory.withUnsafeFileSystemRepresentation { pathPointer -> Int32 in
            guard let pathPointer else { return -1 }
            return open(pathPointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw AssetError.cachePersistenceFailed(
                "Could not open cache root directory (errno \(errno))"
            )
        }
        var rootStat = stat()
        guard fstat(descriptor, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            close(descriptor)
            throw AssetError.cachePersistenceFailed("Cache root is not a verified directory")
        }
        rootFD = descriptor
        rootOwnerUID = rootStat.st_uid
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
        let descriptor = openat(rootFD, name, O_RDONLY | O_NOFOLLOW)
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
            guard readCount > 0 else {
                throw AssetError.cachePersistenceFailed("Short read for '\(name)'")
            }
            totalRead += readCount
        }
        return Data(buffer)
    }

    /// The exact on-disk size and regular-file/ownership verification for
    /// `name`, without reading its contents. Returns `nil` for a clean
    /// miss.
    func attributes(name: String) throws -> (size: Int, isRegularFile: Bool)? {
        var info = stat()
        guard fstatat(rootFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw AssetError.cachePersistenceFailed("fstatat failed for '\(name)' (errno \(errno))")
        }
        let isRegular = (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == rootOwnerUID
        return (size: Int(info.st_size), isRegularFile: isRegular)
    }

    /// Writes `data` to a freshly created (never a pre-existing, possibly
    /// attacker-owned) file at `tempName` — any leftover file at that exact
    /// name is unlinked first — then `fsync`s the file itself before
    /// returning, so the temp file's own bytes are durable on disk before
    /// this cache ever attempts to rename it into place.
    ///
    /// If a test has installed fault injection matching `tempName`'s
    /// final (non-`.tmp`) target name, a truncated one-byte stub is
    /// written at `tempName` (reproducing the shape of a genuine
    /// interrupted write) and this throws instead of performing the real,
    /// full write — exercising the exact same caller cleanup path a real
    /// I/O failure would.
    func writeTempAndFsync(tempName: String, data: Data) throws {
        if faultState.shouldFailTempWrite(tempName: tempName) {
            _ = unlinkat(rootFD, tempName, 0)
            let stubFD = openat(rootFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if stubFD >= 0 {
                var stubByte: UInt8 = 0xFF
                _ = withUnsafeBytes(of: &stubByte) { Darwin.write(stubFD, $0.baseAddress, 1) }
                close(stubFD)
            }
            throw AssetError.cachePersistenceFailed("injected fault: writeTemp '\(tempName)'")
        }
        _ = unlinkat(rootFD, tempName, 0)
        let descriptor = openat(rootFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw AssetError.cachePersistenceFailed(
                "Could not create temp file '\(tempName)' (errno \(errno))"
            )
        }
        defer { close(descriptor) }
        var totalWritten = 0
        let byteCount = data.count
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while totalWritten < byteCount {
                let writeCount = Darwin.write(
                    descriptor, base + totalWritten, byteCount - totalWritten
                )
                guard writeCount > 0 else {
                    throw AssetError.cachePersistenceFailed("Short write for '\(tempName)'")
                }
                totalWritten += writeCount
            }
        }
        guard fsync(descriptor) == 0 else {
            throw AssetError.cachePersistenceFailed("fsync failed for '\(tempName)'")
        }
    }

    /// Atomically renames `tempName` to `finalName` (replacing any existing
    /// file at `finalName`, exactly like `rename(2)`), then `fsync`s the
    /// root directory itself so the rename's directory-entry update is
    /// durable — required so a crash immediately after this call cannot
    /// resurrect the pre-rename state on the next launch.
    func renameAndFsyncDirectory(from tempName: String, to finalName: String) throws {
        guard renameat(rootFD, tempName, rootFD, finalName) == 0 else {
            throw AssetError.cachePersistenceFailed(
                "renameat failed for '\(tempName)' -> '\(finalName)' (errno \(errno))"
            )
        }
        try fsyncRootDirectory()
    }

    /// `fsync`s the root directory descriptor itself, making a prior
    /// `rename`/`unlink` durable. Every crash-consistency boundary in
    /// ``AssetDiskCache`` calls this immediately after any directory-entry
    /// mutation it needs to survive a crash.
    func fsyncRootDirectory() throws {
        guard fsync(rootFD) == 0 else {
            throw AssetError.cachePersistenceFailed("fsync failed for the cache root directory")
        }
    }

    /// Removes `name`. Returns `true` if a file was actually removed,
    /// `false` if `name` did not exist (never an error either way), and
    /// throws only for a genuine, unexpected removal failure (e.g. a
    /// permission error) — the caller decides how to react to a `false`
    /// result (e.g. treating a definitive-404 eviction that could not
    /// physically remove a file as still "invalidated" via its own
    /// tombstone, per ``AssetDiskCache``'s crash/deletion-failure
    /// contract).
    @discardableResult
    func remove(name: String) throws -> Bool {
        if faultState.shouldFailRemove(name: name) {
            throw AssetError.cachePersistenceFailed(
                "injected failure removing '\(name)'"
            )
        }
        guard unlinkat(rootFD, name, 0) == 0 else {
            if errno == ENOENT {
                return false
            }
            throw AssetError.cachePersistenceFailed(
                "unlinkat failed for '\(name)' (errno \(errno))"
            )
        }
        return true
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
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { rawBuffer -> String in
                let pointer = rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self)
                return String(cString: pointer)
            }
            guard name != ".", name != ".." else { continue }
            names.append(name)
        }
        return names
    }

    /// Verifies an already-opened descriptor resolves to a regular file
    /// owned by the same user as the verified root directory — never
    /// trusting `name` alone, since a symlink refused by `O_NOFOLLOW`
    /// already fails at `open`/`openat` time, but a *hardlinked* regular
    /// file swapped in by another user on a shared filesystem would still
    /// open successfully and must be rejected here instead.
    private func requireVerifiedRegularFile(descriptor: Int32, name: String) throws {
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
    }
}

/// Test-only fault-injection state for ``SecureCacheDirectory``, isolated
/// into its own lock-backed type (rather than plain stored properties on
/// `SecureCacheDirectory` itself) so a test can install it and read its
/// call counter from outside the actor that owns the surrounding
/// ``AssetDiskCache`` without any additional synchronization of its own —
/// mirroring `AssetDiskCacheTests.swift`'s pre-existing `AtomicCallCounter`
/// pattern for the same reason (reading a plain property on a value just
/// handed to an actor-isolated initializer trips the compiler's
/// region-isolation "sending" analysis even when every real call site
/// awaits the actor first and so never actually races).
private final class FaultInjectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var _failSuffixes: Set<String> = []
    private var _failPrefixes: Set<String> = []
    private var _failRemoveSuffixes: Set<String> = []
    private var _failRemovePrefixes: Set<String> = []
    private var _listNamesFailuresRemaining = 0
    private var _listNamesCallCount = 0

    var failSuffixes: Set<String> {
        get { lock.withLock { _failSuffixes } }
        set { lock.withLock { _failSuffixes = newValue } }
    }

    var failPrefixes: Set<String> {
        get { lock.withLock { _failPrefixes } }
        set { lock.withLock { _failPrefixes = newValue } }
    }

    var failRemoveSuffixes: Set<String> {
        get { lock.withLock { _failRemoveSuffixes } }
        set { lock.withLock { _failRemoveSuffixes = newValue } }
    }

    var failRemovePrefixes: Set<String> {
        get { lock.withLock { _failRemovePrefixes } }
        set { lock.withLock { _failRemovePrefixes = newValue } }
    }

    var listNamesFailuresRemaining: Int {
        get { lock.withLock { _listNamesFailuresRemaining } }
        set { lock.withLock { _listNamesFailuresRemaining = newValue } }
    }

    var listNamesCallCount: Int {
        lock.withLock { _listNamesCallCount }
    }

    /// `tempName` is always `.tmp`-suffixed (see
    /// ``SecureCacheDirectory/writeTempAndFsync(tempName:data:)``), so
    /// suffixes/prefixes are matched against the *stripped* final name
    /// (without the trailing `.tmp`) to line up with the target filename a
    /// test actually cares about, exactly as `FailingFileManager` matched
    /// against `moveItem`'s destination URL.
    func shouldFailTempWrite(tempName: String) -> Bool {
        let strippedName = tempName.hasSuffix(".tmp") ? String(tempName.dropLast(4)) : tempName
        return lock.withLock {
            _failSuffixes.contains { strippedName.hasSuffix($0) }
                || _failPrefixes.contains { strippedName.hasPrefix($0) }
        }
    }

    /// Independent of `shouldFailTempWrite`: `name` here is already the
    /// exact, final entry name `remove(name:)` was called with (never a
    /// `.tmp` name), so no suffix-stripping is needed.
    func shouldFailRemove(name: String) -> Bool {
        lock.withLock {
            _failRemoveSuffixes.contains { name.hasSuffix($0) }
                || _failRemovePrefixes.contains { name.hasPrefix($0) }
        }
    }

    func recordListNamesCallAndCheckFault() throws {
        let shouldFail: Bool = lock.withLock {
            _listNamesCallCount += 1
            guard _listNamesFailuresRemaining > 0 else { return false }
            _listNamesFailuresRemaining -= 1
            return true
        }
        guard !shouldFail else {
            throw AssetError.cachePersistenceFailed("injected fault: listNames")
        }
    }
}
