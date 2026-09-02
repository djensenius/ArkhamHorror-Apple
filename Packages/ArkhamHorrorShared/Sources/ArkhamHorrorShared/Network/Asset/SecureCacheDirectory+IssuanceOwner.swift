import Darwin
import Foundation

/// A cache-session owner whose advisory lock proves that operations issued
/// by this cache instance can still be completed. It is created under the
/// directory lock before an authority record can name it; after a crash,
/// the kernel releases the lock without relying on elapsed time.
final class CacheIssuanceOwner: @unchecked Sendable {
    static let markerPrefix = ".arkham-cache-issuance-owner-"
    static let markerSuffix = ".lock"
    private static let creationAttemptLimit = 8

    let identifier: AuthorityID
    let markerName: String
    private let descriptor: Int32

    init(rootFD: Int32, rootOwnerUID: uid_t, rootDevice: dev_t) throws {
        let marker = try Self.createMarker(
            rootFD: rootFD,
            rootOwnerUID: rootOwnerUID,
            rootDevice: rootDevice
        )
        identifier = marker.identifier
        markerName = marker.name
        descriptor = marker.descriptor
        CacheIssuanceOwnerRegistry.shared.register(markerName)
    }

    private struct Marker {
        let identifier: AuthorityID
        let name: String
        let descriptor: Int32
    }

    private static func createMarker(
        rootFD: Int32,
        rootOwnerUID: uid_t,
        rootDevice: dev_t
    ) throws -> Marker {
        for _ in 0 ..< creationAttemptLimit {
            let identifier = try AuthorityID.random()
            let name = Self.markerName(for: identifier)
            let descriptor = openat(
                rootFD,
                name,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            if descriptor < 0 {
                if errno == EEXIST {
                    continue
                }
                throw AssetError.cachePersistenceFailed(
                    "Could not create issuance-owner marker (errno \(errno))"
                )
            }
            do {
                try Self.requireVerifiedMarker(
                    descriptor,
                    name: name,
                    rootOwnerUID: rootOwnerUID,
                    rootDevice: rootDevice
                )
                try Self.lockExclusively(descriptor, name: name)
                return Marker(identifier: identifier, name: name, descriptor: descriptor)
            } catch {
                flock(descriptor, LOCK_UN)
                close(descriptor)
                _ = unlinkat(rootFD, name, 0)
                throw error
            }
        }
        throw AssetError.cachePersistenceFailed("Could not allocate a unique issuance-owner marker")
    }

    deinit {
        CacheIssuanceOwnerRegistry.shared.unregister(markerName)
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func markerName(for identifier: AuthorityID) -> String {
        markerPrefix + identifier.hexString + markerSuffix
    }

    static func isMarkerName(_ name: String) -> Bool {
        identifier(fromMarkerName: name) != nil
    }

    static func identifier(fromMarkerName name: String) -> AuthorityID? {
        guard
            name.hasPrefix(markerPrefix),
            name.hasSuffix(markerSuffix)
        else {
            return nil
        }
        let identifierStart = name.index(name.startIndex, offsetBy: markerPrefix.count)
        let identifierEnd = name.index(name.endIndex, offsetBy: -markerSuffix.count)
        guard identifierEnd >= identifierStart else { return nil }
        return AuthorityID(hexString: String(name[identifierStart ..< identifierEnd]))
    }

    private static func requireVerifiedMarker(
        _ descriptor: Int32,
        name: String,
        rootOwnerUID: uid_t,
        rootDevice: dev_t
    ) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw AssetError.cachePersistenceFailed("fstat failed for '\(name)'")
        }
        guard
            (info.st_mode & S_IFMT) == S_IFREG,
            info.st_uid == rootOwnerUID,
            info.st_dev == rootDevice,
            info.st_nlink == 1
        else {
            throw AssetError.cachePersistenceFailed("Issuance-owner marker is not trusted")
        }
    }

    private static func lockExclusively(_ descriptor: Int32, name: String) throws {
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EINTR else {
                throw AssetError.cachePersistenceFailed(
                    "Could not lock issuance-owner marker '\(name)' (errno \(errno))"
                )
            }
        }
    }
}

/// Local registration closes the same-process `flock` semantic gap:
/// implementations may treat independent descriptors opened by one process
/// as non-conflicting, so a sibling cache must recognize its peer session as
/// live without relying on a second kernel lock attempt.
private final class CacheIssuanceOwnerRegistry: @unchecked Sendable {
    static let shared = CacheIssuanceOwnerRegistry()

    private var lock = os_unfair_lock()
    private var markerNames: Set<String> = []

    func register(_ name: String) {
        os_unfair_lock_lock(&lock)
        markerNames.insert(name)
        os_unfair_lock_unlock(&lock)
    }

    func unregister(_ name: String) {
        os_unfair_lock_lock(&lock)
        markerNames.remove(name)
        os_unfair_lock_unlock(&lock)
    }

    func contains(_ name: String) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return markerNames.contains(name)
    }
}

extension SecureCacheDirectory {
    /// `true` if a record's owner session is still demonstrably live,
    /// `false` if its marker is absent or its advisory lock is orphaned,
    /// and `nil` if the marker cannot be safely verified.
    func isIssuanceOwnerLive(_ identifier: AuthorityID) -> Bool? {
        let name = CacheIssuanceOwner.markerName(for: identifier)
        if CacheIssuanceOwnerRegistry.shared.contains(name) {
            return true
        }
        let descriptor = openat(rootFD, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            return errno == ENOENT ? false : nil
        }
        defer { close(descriptor) }
        do {
            try requireVerifiedRegularFile(descriptor: descriptor, name: name)
        } catch {
            return nil
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR {
                continue
            }
            return errno == EWOULDBLOCK ? true : nil
        }
        flock(descriptor, LOCK_UN)
        return false
    }

    static func isIssuanceOwnerMarkerName(_ name: String) -> Bool {
        CacheIssuanceOwner.isMarkerName(name)
    }

    static func issuanceOwnerIdentifier(forMarkerName name: String) -> AuthorityID? {
        CacheIssuanceOwner.identifier(fromMarkerName: name)
    }

    /// Removes unlocked owner markers during one bounded startup-recovery
    /// scan. An unlocked marker is process-crash residue, not a lease that
    /// may expire while legitimate work is still running.
    func reclaimOrphanedIssuanceOwnerMarkers(_ names: [String]) -> Set<String> {
        var removed: Set<String> = []
        for name in names {
            guard let identifier = CacheIssuanceOwner.identifier(fromMarkerName: name) else {
                continue
            }
            guard isIssuanceOwnerLive(identifier) == false else { continue }
            guard (try? remove(name: name)) == true else { continue }
            removed.insert(name)
        }
        return removed
    }
}
