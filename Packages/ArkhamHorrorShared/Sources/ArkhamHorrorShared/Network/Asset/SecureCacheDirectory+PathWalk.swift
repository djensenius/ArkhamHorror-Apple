import Darwin
import Foundation

/// Descriptor-relative creation/verification below a FileManager-provided
/// trust anchor. No metadata is read from the anchor's ancestors.
extension SecureCacheDirectory {
    /// Only mkdirat's own success proves that this call created the leaf.
    /// This race-proof freshness evidence gates clear-epoch initialization;
    /// inspecting the directory's contents afterward cannot replace it.
    struct DirectoryWalkResult {
        let descriptor: Int32
        let leafWasFreshlyCreated: Bool
    }

    static func openOrCreateVerifiedDirectory(
        at directory: URL,
        fileManager: FileManager = .default,
        directoryStat: (Int32, inout stat) -> Int32 = { fstat($0, &$1) }
    ) throws -> DirectoryWalkResult {
        let anchor = try cacheTrustAnchor(for: directory, fileManager: fileManager)
        return try openOrCreateVerifiedDirectory(
            at: directory, trustAnchor: anchor, directoryStat: directoryStat
        )
    }

    /// Opens the existing anchor directly with O_NOFOLLOW, then walks only
    /// strict descendants using mkdirat/openat on the preceding descriptor.
    /// The anchor's ancestors are trusted, not inspected (C617.1). Every
    /// opened directory, including the anchor, retains the owner/mode checks;
    /// components below it retain the no-symlink and device-transition policy.
    /// At most two descriptors are open, and the caller owns the returned one.
    ///
    /// Explicit anchor and fstat injection let tests observe the actual
    /// descriptors inspected and simulate otherwise privileged owner changes.
    static func openOrCreateVerifiedDirectory(
        at directory: URL,
        trustAnchor: URL,
        directoryStat: (Int32, inout stat) -> Int32 = { fstat($0, &$1) }
    ) throws -> DirectoryWalkResult {
        let components = try cacheRelativeComponents(of: directory, below: trustAnchor)
        let anchor = try openAndVerifyCacheTrustAnchor(trustAnchor, directoryStat: directoryStat)
        var currentFD = anchor.descriptor
        let devicePolicy = DeviceTransitionPolicy(rootDevice: anchor.info.st_dev)
        let trustedOwnerUID = getuid()
        var leafWasFreshlyCreated = false
        for component in components {
            do {
                let result = try openVerifiedComponent(
                    parentFD: currentFD,
                    name: component,
                    createIfMissing: true,
                    devicePolicy: devicePolicy,
                    trustedOwnerUID: trustedOwnerUID,
                    directoryStat: directoryStat
                )
                close(currentFD)
                currentFD = result.descriptor
                leafWasFreshlyCreated = result.wasFreshlyCreated
            } catch {
                close(currentFD)
                throw error
            }
        }
        return DirectoryWalkResult(
            descriptor: currentFD,
            leafWasFreshlyCreated: leafWasFreshlyCreated
        )
    }

    private static func openAndVerifyCacheTrustAnchor(
        _ anchor: URL,
        directoryStat: (Int32, inout stat) -> Int32
    ) throws -> (descriptor: Int32, info: stat) {
        let descriptor = open(anchor.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AssetError.cachePersistenceFailed(
                "Could not open cache trust anchor (errno \(errno))"
            )
        }
        var info = stat()
        guard directoryStat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            close(descriptor)
            throw AssetError
                .cachePersistenceFailed("Cache trust anchor is not a verified directory")
        }
        do {
            try requireTrustedAncestor(info: info, name: anchor.path, trustedOwnerUID: getuid())
        } catch {
            close(descriptor)
            throw error
        }
        return (descriptor, info)
    }
}

/// Preserves the walk's existing at-most-one-device-transition policy,
/// now seeded from the container/Caches anchor rather than the filesystem
/// root. A second transition (including a return to the original device)
/// fails closed. This pure policy is also tested with synthetic device IDs.
final class DeviceTransitionPolicy {
    private(set) var currentDevice: dev_t
    private(set) var hasTransitioned = false

    init(rootDevice: dev_t) {
        currentDevice = rootDevice
    }

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
