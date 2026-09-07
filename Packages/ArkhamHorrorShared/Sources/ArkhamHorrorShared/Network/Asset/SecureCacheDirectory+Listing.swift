import Darwin
import Foundation

/// Directory-listing for ``SecureCacheDirectory``, split out of the main
/// class file purely to stay under this package's file-length limit;
/// still instance state/behavior of the same `SecureCacheDirectory`.
extension SecureCacheDirectory {
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
}
