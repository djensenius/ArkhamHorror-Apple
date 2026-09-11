import Darwin
import Foundation

extension ProductionReplayFileSystem {
    static func readVerifiedInput(
        _ inputURL: URL,
        maxByteCount: Int
    ) throws -> Data {
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
        defer { close(descriptor) }

        let before = try inputSnapshot(
            descriptor: descriptor,
            parent: location.parent,
            maxByteCount: maxByteCount
        )
        try validateInputPath(
            location.name,
            parent: location.parent,
            expected: before
        )
        let data = try readAll(
            from: descriptor,
            maxByteCount: maxByteCount
        )

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              sameFileSnapshot(before, after),
              data.count == after.st_size
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        try validateInputPath(
            location.name,
            parent: location.parent,
            expected: after
        )
        return data
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
        maxByteCount: Int
    ) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              isRegular(info),
              info.st_dev == parent.identity.device,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              info.st_size >= 0,
              info.st_size <= maxByteCount
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        return info
    }

    private static func validateInputPath(
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

    private static func sameFileSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
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
