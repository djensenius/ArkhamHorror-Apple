import Darwin
import Foundation

enum ProductionReplayInputPermission {
    case notGroupOrWorldWritable
    case ownerReadWriteOnly
}

final class ProductionReplayInputHandle: @unchecked Sendable {
    let descriptor: Int32
    let parent: ProductionReplayDirectoryHandle
    let name: String
    let snapshot: stat
    let maxByteCount: Int

    private let lock = NSLock()
    private var wasRead = false

    init(
        descriptor: Int32,
        parent: ProductionReplayDirectoryHandle,
        name: String,
        snapshot: stat,
        maxByteCount: Int
    ) {
        self.descriptor = descriptor
        self.parent = parent
        self.name = name
        self.snapshot = snapshot
        self.maxByteCount = maxByteCount
    }

    deinit {
        close(descriptor)
    }

    func readOnce() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !wasRead else {
            throw ProductionReplayDriverError.inputAlreadyRead
        }
        wasRead = true
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        try ProductionReplayFileSystem.validateInputPath(
            name,
            parent: parent,
            expected: snapshot
        )
        let data = try ProductionReplayFileSystem.readAll(
            from: descriptor,
            maxByteCount: maxByteCount
        )
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              ProductionReplayFileSystem.sameFileSnapshot(snapshot, after),
              data.count == after.st_size
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        try ProductionReplayFileSystem.validateInputPath(
            name,
            parent: parent,
            expected: after
        )
        return data
    }
}

extension ProductionReplayFileSystem {
    static func openVerifiedInput(
        _ inputURL: URL,
        maxByteCount: Int,
        permission: ProductionReplayInputPermission =
            .notGroupOrWorldWritable
    ) throws -> ProductionReplayInputHandle {
        let location = try inputLocation(
            for: inputURL,
            maxByteCount: maxByteCount
        )
        let descriptor = openat(
            location.parent.descriptor,
            location.name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        do {
            let snapshot = try inputSnapshot(
                descriptor: descriptor,
                parent: location.parent,
                maxByteCount: maxByteCount,
                permission: permission
            )
            try validateInputPath(
                location.name,
                parent: location.parent,
                expected: snapshot
            )
            return ProductionReplayInputHandle(
                descriptor: descriptor,
                parent: location.parent,
                name: location.name,
                snapshot: snapshot,
                maxByteCount: maxByteCount
            )
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func readVerifiedInput(
        _ inputURL: URL,
        maxByteCount: Int
    ) throws -> Data {
        try openVerifiedInput(
            inputURL,
            maxByteCount: maxByteCount
        ).readOnce()
    }

    private static func inputLocation(
        for inputURL: URL,
        maxByteCount: Int
    ) throws -> (
        parent: ProductionReplayDirectoryHandle,
        name: String
    ) {
        let normalized = try normalizedFileURL(inputURL)
        let parentURL = normalized.deletingLastPathComponent()
        let name = normalized.lastPathComponent
        guard parentURL.path != normalized.path,
              isSafeComponent(name),
              maxByteCount > 0
        else {
            throw ProductionReplayDriverError.invalidResultURL
        }
        return try (openVerifiedParent(parentURL), name)
    }

    private static func inputSnapshot(
        descriptor: Int32,
        parent: ProductionReplayDirectoryHandle,
        maxByteCount: Int,
        permission: ProductionReplayInputPermission
    ) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              isRegular(info),
              info.st_dev == parent.identity.device,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= maxByteCount,
              hasAcceptedInputPermission(info, permission: permission)
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        return info
    }

    private static func hasAcceptedInputPermission(
        _ info: stat,
        permission: ProductionReplayInputPermission
    ) -> Bool {
        switch permission {
        case .notGroupOrWorldWritable:
            info.st_mode & (S_IWGRP | S_IWOTH) == 0
        case .ownerReadWriteOnly:
            info.st_mode & 0o777 == 0o600
        }
    }

    static func validateInputPath(
        _ name: String,
        parent: ProductionReplayDirectoryHandle,
        expected: stat
    ) throws {
        var pathInfo = stat()
        guard fstatat(
            parent.descriptor,
            name,
            &pathInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            sameFileSnapshot(pathInfo, expected)
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
    }

    static func sameFileSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_uid == rhs.st_uid &&
            lhs.st_nlink == rhs.st_nlink &&
            lhs.st_mode == rhs.st_mode &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
