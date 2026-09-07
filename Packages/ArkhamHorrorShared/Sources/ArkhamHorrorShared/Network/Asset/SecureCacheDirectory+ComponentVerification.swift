import Darwin
import Foundation

/// Per-component descriptor-relative verification for
/// ``SecureCacheDirectory/openOrCreateVerifiedDirectory(at:)``'s walk,
/// split out of `SecureCacheDirectory+PathWalk.swift` purely to stay
/// under this package's file-length limit.
extension SecureCacheDirectory {
    /// The owner/permission policy shared by every component of the walk
    /// (including the filesystem root itself): a world-writable directory
    /// is rejected unconditionally, and ownership must be either `root`
    /// (tolerating a pre-existing, OS-managed ancestor this cache does not
    /// itself own) or `trustedOwnerUID` (this process's own real user ID)
    /// -- never a third owner, which would mean some other, untrusted
    /// principal controls a directory somewhere between the filesystem
    /// root and this cache's own data.
    static func requireTrustedAncestor(
        info: stat,
        name: String,
        trustedOwnerUID: uid_t
    ) throws {
        guard info.st_uid == 0 || info.st_uid == trustedOwnerUID else {
            throw AssetError.cachePersistenceFailed(
                "Path component '\(name)' has an untrusted owner"
            )
        }
        guard info.st_mode & S_IWOTH == 0 else {
            throw AssetError.cachePersistenceFailed(
                "Path component '\(name)' is world-writable"
            )
        }
    }

    /// Opens `name` directly under `parentFD` with `O_NOFOLLOW` (never
    /// following a symlink planted at this exact path component,
    /// regardless of which component in the overall walk this is),
    /// creating it via `mkdirat` first if `createIfMissing` is `true` and
    /// it does not yet exist, and verifying the opened descriptor is
    /// actually a directory -- on the expected device (either a fixed
    /// `expectedDevice`, for a single standalone call, or `devicePolicy`'s
    /// own tolerant-of-one-transition policy, for a call that is part of
    /// ``openOrCreateVerifiedDirectory(at:)``'s own walk), owned by
    /// either `root` or `trustedOwnerUID`, and not world-writable --
    /// before returning it. A symlink, a regular file, any other
    /// non-directory entry, or a directory that fails any of those
    /// checks occupying `name` fails closed here rather than being
    /// silently traversed, trusted, or replaced.
    ///
    /// `expectedDevice` and `devicePolicy` are mutually exclusive in
    /// practice (never both non-`nil` from any real call site): the
    /// former is used only by tests exercising this function in
    /// isolation against a single, fixed expected device; the latter is
    /// used only by the walk itself, which must tolerate the single
    /// legitimate device transition a real device can produce (see
    /// ``DeviceTransitionPolicy``'s own doc comment).
    /// The return value's `wasFreshlyCreated` is `true` if and only if
    /// *this exact call's own* `mkdirat` returned `0` (i.e. this call
    /// itself won the race to create `name`) — `false` for every other
    /// outcome, including the component already existing before this
    /// call, and a concurrent creator winning the race instead (observed
    /// here as `mkdirat` failing with `EEXIST`). This is deliberately
    /// call-scoped, un-cached, race-proof evidence: see
    /// ``DirectoryWalkResult``'s own doc comment for why only the walk's
    /// own *final* component's value is ever load-bearing.
    static func openVerifiedComponent(
        parentFD: Int32,
        name: String,
        createIfMissing: Bool,
        expectedDevice: dev_t? = nil,
        devicePolicy: DeviceTransitionPolicy? = nil,
        trustedOwnerUID: uid_t? = nil
    ) throws -> (descriptor: Int32, wasFreshlyCreated: Bool) {
        let (descriptor, wasFreshlyCreated) = try openOrCreateRawComponent(
            parentFD: parentFD,
            name: name,
            createIfMissing: createIfMissing
        )
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            close(descriptor)
            throw AssetError.cachePersistenceFailed("fstat failed for '\(name)'")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            close(descriptor)
            throw AssetError.cachePersistenceFailed(
                "Directory component '\(name)' is not a verified directory"
            )
        }
        if let expectedDevice, info.st_dev != expectedDevice {
            close(descriptor)
            throw AssetError.cachePersistenceFailed(
                "Directory component '\(name)' is not on the expected device"
            )
        }
        if let devicePolicy, !devicePolicy.accepts(info.st_dev) {
            close(descriptor)
            throw AssetError.cachePersistenceFailed(
                "Directory component '\(name)' is a second, unexpected device transition"
            )
        }
        if let trustedOwnerUID {
            do {
                try requireTrustedAncestor(
                    info: info,
                    name: name,
                    trustedOwnerUID: trustedOwnerUID
                )
            } catch {
                close(descriptor)
                throw error
            }
        }
        return (descriptor, wasFreshlyCreated)
    }

    /// Opens `name` directly under `parentFD` with `O_NOFOLLOW`,
    /// creating it via `mkdirat` first (tolerating a concurrent creator
    /// winning the race, observed as `EEXIST`) if `createIfMissing` is
    /// `true` and it does not yet exist. Factored out of
    /// ``openVerifiedComponent`` purely so that function's own body
    /// stays under this package's `function_body_length` limit;
    /// performs no verification of the
    /// resulting descriptor itself (device/ownership/directory-ness),
    /// which remains entirely that caller's own responsibility.
    private static func openOrCreateRawComponent(
        parentFD: Int32,
        name: String,
        createIfMissing: Bool
    ) throws -> (descriptor: Int32, wasFreshlyCreated: Bool) {
        var descriptor = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var wasFreshlyCreated = false
        if descriptor < 0, errno == ENOENT, createIfMissing {
            let createResult = mkdirat(parentFD, name, 0o700)
            guard createResult == 0 || errno == EEXIST else {
                throw AssetError.cachePersistenceFailed(
                    "Could not create directory component '\(name)' (errno \(errno))"
                )
            }
            wasFreshlyCreated = createResult == 0
            descriptor = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw AssetError.cachePersistenceFailed(
                "Could not open directory component '\(name)' (errno \(errno))"
            )
        }
        return (descriptor, wasFreshlyCreated)
    }
}
