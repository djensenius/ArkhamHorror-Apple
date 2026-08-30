import Darwin
import Foundation

/// The descriptor-relative root-path creation/verification walk behind
/// ``SecureCacheDirectory``'s `init`. Split out of the main class file
/// purely to stay under this package's file- and type-body-length
/// limits; both members here are pure, instance-independent helpers
/// used only from `init`.
extension SecureCacheDirectory {
    /// Descriptor-relative equivalent of
    /// `FileManager.createDirectory(at:withIntermediateDirectories:true)`:
    /// starts from the filesystem root (`/`, opened with `O_NOFOLLOW`) and
    /// walks every path component of `directory`'s standardized, absolute
    /// path via `openVerifiedComponent(parentFD:name:createIfMissing:...)`,
    /// creating any component that does not yet exist. Every intermediate
    /// descriptor is closed once the next component's own descriptor is
    /// successfully opened off it, so at most two directory descriptors
    /// are ever open at once during the walk, and the final component's
    /// descriptor is the only one returned (owned by the caller from this
    /// point on).
    ///
    /// Every component -- not merely the final leaf -- is additionally
    /// required to stay on a single consistent device, tolerating **at
    /// most one** transition anywhere along the walk (rejecting a bind
    /// mount, a different volume, or any other cross-device substitution
    /// beyond that single tolerated transition -- see
    /// ``DeviceTransitionPolicy``'s own doc comment for why exactly one
    /// transition, not zero, must be tolerated on real iOS-family
    /// hardware), and to be owned either by `root` (tolerating
    /// pre-existing, OS-managed ancestors such as `/` or `/Users` itself)
    /// or by this process's own real user ID (this cache's own,
    /// self-created subtree) -- never any other, third-party owner. A
    /// world-writable directory anywhere in the chain is rejected
    /// outright regardless of its owner: on a real, single-user macOS
    /// installation this walk never observes more than zero device
    /// transitions at all (verified directly against this machine's own
    /// `/`, `/Users`, `$HOME`, `$HOME/Library`, `$HOME/Library/Caches` --
    /// all report the identical `st_dev`, thanks to APFS firmlinks
    /// presenting the System and Data volumes as one unified path
    /// namespace), and on real iOS-family hardware it observes at most
    /// the one legitimate System/Data transition, so this policy costs
    /// nothing in the common case while closing off an entire class of
    /// mount-point/ownership substitution attacks against every
    /// intermediate component, not merely the leaf
    /// ``SecureCacheDirectory`` itself already fully verifies.
    static func openOrCreateVerifiedDirectory(at directory: URL) throws -> Int32 {
        let standardized = directory.standardizedFileURL
        var components = standardized.pathComponents.filter { $0 != "/" }
        // A `directory` that standardizes to the filesystem root itself
        // (`/`) has zero path components, so the walk below would never
        // execute and would hand back an open descriptor to `/` as though
        // it were a verified, cache-owned directory. Reject this before
        // opening anything: even though no caller in this package passes
        // such a path today, silently treating `/` as the cache root
        // would turn every subsequent create/remove/enumerate operation
        // into an operation against the entire filesystem root.
        guard !components.isEmpty else {
            throw AssetError.cachePersistenceFailed(
                "Refusing to use the filesystem root as a cache directory"
            )
        }
        // Well-known, immutable Darwin compatibility symlinks at the
        // very top level of the filesystem (`/tmp`, `/var`, `/etc`, each
        // a fixed symlink to `/private/<name>`) are transparently
        // rewritten to their real target *before* the strict walk below
        // ever runs, rather than being rejected by it: `openat` with
        // `O_NOFOLLOW` fails with `ELOOP` on any symlink, and nearly
        // every real-world cache directory this initializer is ever
        // asked to open — iOS container paths under
        // `/var/mobile/Containers/...`, and macOS/iOS sandboxed apps'
        // own `NSTemporaryDirectory()`/`.cachesDirectory` results under
        // `/var/folders/...` — is expressed through exactly this
        // compatibility form, never the `/private/...` physical form.
        // Rejecting them outright would make this cache unusable on
        // essentially every real device.
        //
        // This rewrite only ever fires for the *first* path component,
        // and only for this exact, fixed three-name set: it never
        // applies anywhere else in the path. Critically, it is purely
        // advisory — it only decides *which literal path string* the
        // walk below attempts — and is not itself relied on for any
        // security property: the strict, unchanged per-component walk
        // (`O_NOFOLLOW`, ownership, device checks, all via
        // ``openVerifiedComponent(parentFD:name:createIfMissing:expectedDevice:trustedOwnerUID:)``)
        // still fully, independently re-verifies `private`, then
        // `tmp`/`var`/`etc`, exactly as it would any other component.
        // A `TOCTOU` race that somehow altered `/tmp`/`/var`/`/etc`
        // between this check and the walk below changes at most
        // *which* literal path gets attempted; it can never cause the
        // walk itself to trust an unverified symlink, since every
        // resulting component is still opened with `O_NOFOLLOW` and
        // checked for device/ownership by that same unmodified walk.
        if let first = components.first, ["tmp", "var", "etc"].contains(first) {
            if let resolved = resolvedWellKnownTopLevelCompatibilitySymlink(name: first) {
                components.replaceSubrange(0 ... 0, with: resolved)
            }
        }
        var currentFD = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard currentFD >= 0 else {
            throw AssetError.cachePersistenceFailed(
                "Could not open filesystem root (errno \(errno))"
            )
        }
        var rootInfo = stat()
        guard fstat(currentFD, &rootInfo) == 0 else {
            close(currentFD)
            throw AssetError.cachePersistenceFailed("fstat failed for the filesystem root")
        }
        do {
            try requireTrustedAncestor(info: rootInfo, name: "/", trustedOwnerUID: getuid())
        } catch {
            close(currentFD)
            throw error
        }
        let devicePolicy = DeviceTransitionPolicy(rootDevice: rootInfo.st_dev)
        let trustedOwnerUID = getuid()
        for component in components {
            do {
                let nextFD = try openVerifiedComponent(
                    parentFD: currentFD,
                    name: component,
                    createIfMissing: true,
                    devicePolicy: devicePolicy,
                    trustedOwnerUID: trustedOwnerUID
                )
                close(currentFD)
                currentFD = nextFD
            } catch {
                // `openVerifiedComponent` failing mid-walk must not leak
                // the parent descriptor this iteration was about to
                // replace: without this, a failure at any component
                // deeper than the first (e.g. a non-directory occupying
                // an intermediate path segment) would leave `currentFD`
                // open with nothing left holding a reference to ever
                // close it, since the walk never reaches the `return`
                // that would otherwise hand ownership to the caller.
                close(currentFD)
                throw error
            }
        }
        return currentFD
    }

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
    static func openVerifiedComponent(
        parentFD: Int32,
        name: String,
        createIfMissing: Bool,
        expectedDevice: dev_t? = nil,
        devicePolicy: DeviceTransitionPolicy? = nil,
        trustedOwnerUID: uid_t? = nil
    ) throws -> Int32 {
        var descriptor = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT, createIfMissing {
            guard mkdirat(parentFD, name, 0o700) == 0 || errno == EEXIST else {
                throw AssetError.cachePersistenceFailed(
                    "Could not create directory component '\(name)' (errno \(errno))"
                )
            }
            descriptor = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw AssetError.cachePersistenceFailed(
                "Could not open directory component '\(name)' (errno \(errno))"
            )
        }
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
        return descriptor
    }

    /// If `/name` (`name` one of `"tmp"`, `"var"`, `"etc"`) is currently a
    /// symbolic link whose target is exactly `private/name` — the fixed
    /// Darwin compatibility form for these three well-known top-level
    /// symlinks — returns the replacement path components
    /// (`["private", name]`) that should be walked instead. Returns
    /// `nil` for anything else at all: `/name` not existing, not being a
    /// symlink, or being a symlink to any other target (an attacker- or
    /// misconfiguration-planted symlink at this exact position must
    /// never be silently substituted for anything, so this check is
    /// deliberately narrow and exact rather than "resolve whatever this
    /// happens to point to").
    ///
    /// Uses a plain, unverified `lstat`/`readlink` pair rather than the
    /// descriptor-relative, verified primitives used elsewhere in this
    /// file: this result is never trusted on its own (see
    /// ``openOrCreateVerifiedDirectory(at:)``'s doc comment for why a
    /// race here is harmless — the actual walk independently re-verifies
    /// every resulting component with `O_NOFOLLOW`/ownership/device
    /// checks regardless of what this function returns).
    private static func resolvedWellKnownTopLevelCompatibilitySymlink(
        name: String
    ) -> [String]? {
        var linkInfo = stat()
        guard lstat("/\(name)", &linkInfo) == 0 else { return nil }
        guard (linkInfo.st_mode & S_IFMT) == S_IFLNK else { return nil }
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink("/\(name)", &buffer, buffer.count - 1)
        guard length > 0 else { return nil }
        buffer[length] = 0
        let target = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard target == "private/\(name)" else { return nil }
        return ["private", name]
    }
}

/// A device-identity policy for a single call to
/// ``SecureCacheDirectory/openOrCreateVerifiedDirectory(at:)``: requires
/// every path component to stay on one consistent device, while
/// tolerating **at most one** transition to a second device partway
/// through the walk.
///
/// That one tolerated transition is the sole legitimate case a real
/// device produces: on the iOS family, `/` (the read-only System volume)
/// and `/var` (reached only via the fixed `/var` -> `/private/var`
/// compatibility symlink, physically on the separate, writable Data
/// volume) are two different APFS volumes that Darwin's own volume-group
/// firmlink mechanism presents as one unified path namespace -- so a real
/// container path such as
/// `/var/mobile/Containers/Data/Application/<UUID>/Library/Caches/...`
/// genuinely, legitimately changes `st_dev` exactly once, at the `/` ->
/// `private` boundary, never again below that. Requiring every single
/// component to share the filesystem root's own device (this type's
/// predecessor) rejected every such path outright on real iOS-family
/// hardware, even though it is the OS's own normal, unremarkable
/// directory layout. A *second* transition, anywhere else in the walk,
/// still indicates a genuine bind-mount or volume substitution planted
/// inside what should otherwise be a single, coherent subtree, and is
/// rejected exactly as strictly as a same-device build would reject any
/// mismatch.
///
/// A plain reference type (rather than plumbing `inout` through every
/// `openVerifiedComponent(...)` call in the walk's loop) purely so its
/// mutable "has a transition already been spent" state threads through
/// an ordinary value-returning helper function without changing that
/// function's calling convention.
///
/// Deliberately a small, pure, filesystem-independent type: `accepts(_:)`
/// needs no I/O of its own, so a test can exercise every same-device /
/// one-transition / second-transition sequence directly, with entirely
/// synthetic `dev_t` values, proving this policy's actual decision logic
/// without needing a real, second mounted physical volume -- unavailable
/// in a hosted CI/test environment, and the actual reason the review that
/// flagged this required an "injectable production-anchor" test seam
/// rather than a real-hardware-only regression.
final class DeviceTransitionPolicy {
    private(set) var currentDevice: dev_t
    private(set) var hasTransitioned = false

    init(rootDevice: dev_t) {
        currentDevice = rootDevice
    }

    /// Validates `candidateDevice` against the current device, updating
    /// state to accept a legitimate single transition. Returns `false`
    /// if `candidateDevice` differs from `currentDevice` and a
    /// transition has already been spent earlier in this same walk.
    @discardableResult
    func accepts(_ candidateDevice: dev_t) -> Bool {
        if candidateDevice == currentDevice {
            return true
        }
        guard !hasTransitioned else { return false }
        hasTransitioned = true
        currentDevice = candidateDevice
        return true
    }
}
