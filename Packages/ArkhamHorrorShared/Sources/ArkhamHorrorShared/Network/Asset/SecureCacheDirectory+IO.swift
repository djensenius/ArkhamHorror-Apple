import Darwin
import Foundation

/// The temp-file-write/fsync/rename/remove primitives behind
/// ``SecureCacheDirectory``'s crash-durable publication contract. Split
/// out of the main class file purely to stay under this package's
/// file- and type-body-length limits; every member here is still
/// instance state/behavior of the same `SecureCacheDirectory`.
extension SecureCacheDirectory {
    func writeTempAndFsync(tempName: String, data: Data) throws {
        if faultState.shouldFailTempWrite(tempName: tempName) {
            _ = unlinkat(rootFD, tempName, 0)
            let stubFD = openat(
                rootFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
            )
            if stubFD >= 0 {
                var stubByte: UInt8 = 0xFF
                _ = withUnsafeBytes(of: &stubByte) { Darwin.write(stubFD, $0.baseAddress, 1) }
                close(stubFD)
            }
            throw AssetError.cachePersistenceFailed("injected fault: writeTemp '\(tempName)'")
        }
        _ = unlinkat(rootFD, tempName, 0)
        let descriptor = openat(
            rootFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
        )
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
                if writeCount < 0 {
                    // A `write()` interrupted by a signal (`EINTR`) is
                    // not a genuine failure and must be retried rather
                    // than surfaced as a spurious persistence failure;
                    // any other negative result is a real failure,
                    // reported with its errno for diagnosability.
                    if errno == EINTR {
                        continue
                    }
                    throw AssetError.cachePersistenceFailed(
                        "write failed for '\(tempName)' (errno \(errno))"
                    )
                }
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
    /// file at `finalName`, exactly like `rename(2)`), *without* fsyncing
    /// the containing directory. Once this returns successfully, the
    /// rename has already taken effect for this (and any other) currently
    /// running process — `rename(2)` is not itself a two-phase operation —
    /// only its durability across a crash is still unconfirmed until a
    /// separate ``fsyncRootDirectory()`` call succeeds.
    ///
    /// This is deliberately a distinct, separately-throwing step from
    /// ``renameAndFsyncDirectory(from:to:)`` (which simply calls this then
    /// ``fsyncRootDirectory()``) so a caller that must react differently to
    /// "the rename itself never happened" (safe to roll back whatever it
    /// was about to publish — nothing changed) versus "the rename
    /// succeeded but the following directory fsync failed" (the rename
    /// *already* took effect; anything now referencing its target must
    /// not be rolled back, or a reference that is already live in the
    /// current process would be broken immediately, not merely at some
    /// future crash) can distinguish the two by which specific call threw.
    /// See ``AssetDiskCache/set(_:payload:metadata:token:)``'s metadata
    /// pointer commit for the one call site where this distinction is
    /// load-bearing.
    func rename(from tempName: String, to finalName: String) throws {
        guard renameat(rootFD, tempName, rootFD, finalName) == 0 else {
            throw AssetError.cachePersistenceFailed(
                "renameat failed for '\(tempName)' -> '\(finalName)' (errno \(errno))"
            )
        }
        faultState.recordRename(finalName: finalName)
    }

    /// Atomically renames `tempName` to `finalName` (replacing any existing
    /// file at `finalName`, exactly like `rename(2)`), then `fsync`s the
    /// root directory itself so the rename's directory-entry update is
    /// durable — required so a crash immediately after this call cannot
    /// resurrect the pre-rename state on the next launch.
    func renameAndFsyncDirectory(from tempName: String, to finalName: String) throws {
        try rename(from: tempName, to: finalName)
        try fsyncRootDirectory()
    }

    /// `fsync`s the root directory descriptor itself, making a prior
    /// `rename`/`unlink` durable. Every crash-consistency boundary in
    /// ``AssetDiskCache`` calls this immediately after any directory-entry
    /// mutation it needs to survive a crash.
    func fsyncRootDirectory() throws {
        let shouldFail = faultState.shouldFailNextDirectoryFsync()
            || faultState.shouldFailRootFsyncUnconditionally()
        if shouldFail {
            throw AssetError.cachePersistenceFailed("injected fault: cache root directory fsync")
        }
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
}
