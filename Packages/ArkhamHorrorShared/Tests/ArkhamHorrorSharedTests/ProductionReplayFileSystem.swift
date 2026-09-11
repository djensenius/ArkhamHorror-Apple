import Darwin
import Foundation

struct ProductionReplayParentIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t

    init(device: dev_t, inode: ino_t) {
        self.device = device
        self.inode = inode
    }

    init(environment: [String: String]) throws {
        guard let rawDevice = environment[ProductionReplayEnvironmentKey.parentDevice],
              let rawInode = environment[ProductionReplayEnvironmentKey.parentInode]
        else {
            throw ProductionReplayDriverError.missingParentIdentity
        }
        guard let device = Int32(rawDevice),
              let inode = UInt64(rawInode)
        else {
            throw ProductionReplayDriverError.invalidParentIdentity
        }
        self.init(device: device, inode: inode)
    }
}

final class ProductionReplayDirectoryHandle: @unchecked Sendable {
    let descriptor: Int32
    let identity: ProductionReplayParentIdentity

    init(descriptor: Int32, info: stat) {
        self.descriptor = descriptor
        identity = ProductionReplayParentIdentity(
            device: info.st_dev,
            inode: info.st_ino
        )
    }

    deinit {
        close(descriptor)
    }
}

struct ProductionReplayDestination: Sendable {
    let finalURL: URL
    let parentURL: URL
    let finalName: String
    let parent: ProductionReplayDirectoryHandle
}

struct ProductionReplayStagingDestination: Sendable {
    let url: URL
    let name: String
}

enum ProductionReplayFileSystem {
    static func validateFinalDestination(
        _ resultURL: URL
    ) throws -> ProductionReplayDestination {
        let normalized = try normalizedFileURL(resultURL)
        let parentURL = normalized.deletingLastPathComponent()
        let finalName = normalized.lastPathComponent
        guard parentURL.path != normalized.path, isSafeComponent(finalName) else {
            throw ProductionReplayDriverError.invalidResultURL
        }
        let parent = try openVerifiedParent(parentURL)
        try validateFinalEntry(finalName, parent: parent)
        return ProductionReplayDestination(
            finalURL: normalized,
            parentURL: parentURL,
            finalName: finalName,
            parent: parent
        )
    }

    static func validateNewStagingDestination(
        _ resultURL: URL
    ) throws -> ProductionReplayDestination {
        let destination = try validateFinalDestination(resultURL)
        var info = stat()
        guard fstatat(
            destination.parent.descriptor,
            destination.finalName,
            &info,
            AT_SYMLINK_NOFOLLOW
        ) != 0, errno == ENOENT
        else {
            throw ProductionReplayDriverError.stagingPathUnavailable
        }
        return destination
    }

    static func makeStagingDestination(
        for destination: ProductionReplayDestination
    ) throws -> ProductionReplayStagingDestination {
        for _ in 0 ..< 8 {
            let name = ".\(destination.finalName).production-replay-" +
                "\(UUID().uuidString).staging"
            var info = stat()
            if fstatat(
                destination.parent.descriptor,
                name,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) != 0, errno == ENOENT {
                return ProductionReplayStagingDestination(
                    url: destination.parentURL.appendingPathComponent(name),
                    name: name
                )
            }
        }
        throw ProductionReplayDriverError.stagingPathUnavailable
    }

    static func writeStagingArtifact(
        _ data: Data,
        to destination: ProductionReplayDestination
    ) throws {
        let descriptor = openat(
            destination.parent.descriptor,
            destination.finalName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw ProductionReplayDriverError.stagingPathUnavailable
        }
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove {
                _ = unlinkat(
                    destination.parent.descriptor,
                    destination.finalName,
                    0
                )
            }
        }

        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw ProductionReplayDriverError.resultWriteFailed(errno)
        }
        try validateRegularArtifact(
            descriptor: descriptor,
            parentIdentity: destination.parent.identity
        )
        shouldRemove = false
    }

    static func validateStagingArtifact(
        _ staging: ProductionReplayStagingDestination,
        parent: ProductionReplayDirectoryHandle
    ) throws {
        var info = stat()
        guard fstatat(
            parent.descriptor,
            staging.name,
            &info,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            isRegular(info),
            info.st_dev == parent.identity.device,
            info.st_uid == geteuid(),
            info.st_nlink == 1
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
    }

    static func publish(
        _ staging: ProductionReplayStagingDestination,
        to destination: ProductionReplayDestination
    ) throws {
        let currentDestination = try validateFinalDestination(destination.finalURL)
        guard currentDestination.parent.identity == destination.parent.identity else {
            throw ProductionReplayDriverError.unsafeResultParent
        }
        guard renameat(
            destination.parent.descriptor,
            staging.name,
            destination.parent.descriptor,
            destination.finalName
        ) == 0 else {
            throw ProductionReplayDriverError.resultPublishFailed(errno)
        }
        try validatePublishedArtifact(destination)
    }

    static func removeStagingIfPresent(
        _ staging: ProductionReplayStagingDestination,
        parent: ProductionReplayDirectoryHandle
    ) {
        guard unlinkat(parent.descriptor, staging.name, 0) != 0,
              errno != ENOENT
        else {
            return
        }
        _ = unlinkat(parent.descriptor, staging.name, AT_REMOVEDIR)
    }

    static func readPublishedArtifact(
        _ destination: ProductionReplayDestination
    ) throws -> Data {
        // A substituted FIFO must not block before descriptor validation rejects it.
        let descriptor = openat(
            destination.parent.descriptor,
            destination.finalName,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        defer { close(descriptor) }
        try validateRegularArtifact(
            descriptor: descriptor,
            parentIdentity: destination.parent.identity
        )
        return try readAll(from: descriptor)
    }

    static func readStagingArtifact(
        _ staging: ProductionReplayStagingDestination,
        parent: ProductionReplayDirectoryHandle
    ) throws -> Data {
        let descriptor = openat(
            parent.descriptor,
            staging.name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        defer { close(descriptor) }
        try validateRegularArtifact(
            descriptor: descriptor,
            parentIdentity: parent.identity
        )
        return try readAll(from: descriptor)
    }
}
