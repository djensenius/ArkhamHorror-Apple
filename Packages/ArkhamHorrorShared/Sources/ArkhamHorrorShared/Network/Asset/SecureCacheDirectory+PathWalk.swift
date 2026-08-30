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
    /// path via ``openVerifiedComponent(parentFD:name:createIfMissing:)``,
    /// creating any component that does not yet exist. Every intermediate
    /// descriptor is closed once the next component's own descriptor is
    /// successfully opened off it, so at most two directory descriptors
    /// are ever open at once during the walk, and the final component's
    /// descriptor is the only one returned (owned by the caller from this
    /// point on).
    static func openOrCreateVerifiedDirectory(at directory: URL) throws -> Int32 {
        let standardized = directory.standardizedFileURL
        let components = standardized.pathComponents.filter { $0 != "/" }
        var currentFD = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard currentFD >= 0 else {
            throw AssetError.cachePersistenceFailed(
                "Could not open filesystem root (errno \(errno))"
            )
        }
        for component in components {
            do {
                let nextFD = try openVerifiedComponent(
                    parentFD: currentFD,
                    name: component,
                    createIfMissing: true
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

    /// Opens `name` directly under `parentFD` with `O_NOFOLLOW` (never
    /// following a symlink planted at this exact path component,
    /// regardless of which component in the overall walk this is),
    /// creating it via `mkdirat` first if `createIfMissing` is `true` and
    /// it does not yet exist, and verifying the opened descriptor is
    /// actually a directory before returning it. A symlink, a regular
    /// file, or any other non-directory entry occupying `name` fails
    /// closed here rather than being silently traversed or replaced.
    static func openVerifiedComponent(
        parentFD: Int32,
        name: String,
        createIfMissing: Bool
    ) throws -> Int32 {
        var descriptor = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if descriptor < 0, errno == ENOENT, createIfMissing {
            guard mkdirat(parentFD, name, 0o700) == 0 || errno == EEXIST else {
                throw AssetError.cachePersistenceFailed(
                    "Could not create directory component '\(name)' (errno \(errno))"
                )
            }
            descriptor = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
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
        return descriptor
    }
}
