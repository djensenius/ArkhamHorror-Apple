import Darwin
import Foundation

struct ProductionReplayArtifactIdentity: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }
}

final class ProductionReplayStagingArtifact: @unchecked Sendable {
    let descriptor: Int32
    let identity: ProductionReplayArtifactIdentity
    let data: Data

    init(
        descriptor: Int32,
        identity: ProductionReplayArtifactIdentity,
        data: Data
    ) {
        self.descriptor = descriptor
        self.identity = identity
        self.data = data
    }

    deinit {
        close(descriptor)
    }
}

struct ProductionReplayPublishedArtifact: Sendable {
    let identity: ProductionReplayArtifactIdentity
    let data: Data
}

extension ProductionReplayFileSystem {
    static func openStagingArtifact(
        _ staging: ProductionReplayStagingDestination,
        parent: ProductionReplayDirectoryHandle
    ) throws -> ProductionReplayStagingArtifact {
        let descriptor = try openArtifactDescriptor(
            named: staging.name,
            parent: parent
        )
        do {
            let observed = try readStableArtifact(
                descriptor: descriptor,
                parentIdentity: parent.identity
            )
            try validateArtifactPath(
                staging.name,
                parent: parent,
                expected: observed.snapshot
            )
            return ProductionReplayStagingArtifact(
                descriptor: descriptor,
                identity: ProductionReplayArtifactIdentity(
                    observed.snapshot
                ),
                data: observed.data
            )
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func readPublishedArtifact(
        _ destination: ProductionReplayDestination
    ) throws -> Data {
        try readNamedArtifact(
            destination.finalName,
            parent: destination.parent
        ).data
    }

    static func readPublishedArtifact(
        _ destination: ProductionReplayDestination,
        expected: ProductionReplayPublishedArtifact
    ) throws -> Data {
        let observed = try readNamedArtifact(
            destination.finalName,
            parent: destination.parent
        )
        guard observed.identity == expected.identity,
              observed.data == expected.data
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        return observed.data
    }

    static func validateFinalEntry(
        _ name: String,
        parent: ProductionReplayDirectoryHandle
    ) throws {
        var info = stat()
        if fstatat(
            parent.descriptor,
            name,
            &info,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            guard isRegular(info),
                  info.st_dev == parent.identity.device
            else {
                throw ProductionReplayDriverError.resultDestinationNotRegular
            }
        } else if errno != ENOENT {
            throw ProductionReplayDriverError.invalidResultURL
        }
    }

    static func validateRegularArtifact(
        descriptor: Int32,
        parentIdentity: ProductionReplayParentIdentity
    ) throws {
        _ = try regularArtifactSnapshot(
            descriptor: descriptor,
            parentIdentity: parentIdentity
        )
    }

    static func regularArtifactSnapshot(
        descriptor: Int32,
        parentIdentity: ProductionReplayParentIdentity
    ) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              isRegular(info),
              info.st_dev == parentIdentity.device,
              info.st_uid == geteuid(),
              info.st_nlink == 1
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        return info
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    let errorCode = written < 0 ? errno : EIO
                    throw ProductionReplayDriverError.resultWriteFailed(
                        errorCode
                    )
                }
                offset += written
            }
        }
    }

    static func readAll(
        from descriptor: Int32,
        maxByteCount: Int
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 {
                return result
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                throw ProductionReplayDriverError.resultMissingOrNotRegular
            }
            guard result.count <= maxByteCount - count else {
                throw ProductionReplayDriverError.resultTooLarge
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func isRegular(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG
    }

    private static func openArtifactDescriptor(
        named name: String,
        parent: ProductionReplayDirectoryHandle
    ) throws -> Int32 {
        // A substituted FIFO must not block before descriptor validation rejects it.
        let descriptor = openat(
            parent.descriptor,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        return descriptor
    }

    static func readStableArtifact(
        descriptor: Int32,
        parentIdentity: ProductionReplayParentIdentity
    ) throws -> (data: Data, snapshot: stat) {
        let before = try regularArtifactSnapshot(
            descriptor: descriptor,
            parentIdentity: parentIdentity
        )
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        let data = try readAll(
            from: descriptor,
            maxByteCount: maximumArtifactByteCount
        )
        let after = try regularArtifactSnapshot(
            descriptor: descriptor,
            parentIdentity: parentIdentity
        )
        guard sameFileSnapshot(before, after),
              off_t(data.count) == after.st_size
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        return (data, after)
    }

    static func validateArtifactPath(
        _ name: String,
        parent: ProductionReplayDirectoryHandle,
        expected: stat
    ) throws {
        let observed = try artifactPathSnapshot(
            name,
            parent: parent
        )
        guard sameFileSnapshot(observed, expected) else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
    }

    static func artifactPathSnapshot(
        _ name: String,
        parent: ProductionReplayDirectoryHandle
    ) throws -> stat {
        var info = stat()
        guard fstatat(
            parent.descriptor,
            name,
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
        return info
    }

    private static func readNamedArtifact(
        _ name: String,
        parent: ProductionReplayDirectoryHandle
    ) throws -> (
        data: Data,
        identity: ProductionReplayArtifactIdentity
    ) {
        let descriptor = try openArtifactDescriptor(
            named: name,
            parent: parent
        )
        defer { close(descriptor) }
        let observed = try readStableArtifact(
            descriptor: descriptor,
            parentIdentity: parent.identity
        )
        try validateArtifactPath(
            name,
            parent: parent,
            expected: observed.snapshot
        )
        return (
            observed.data,
            ProductionReplayArtifactIdentity(observed.snapshot)
        )
    }
}
