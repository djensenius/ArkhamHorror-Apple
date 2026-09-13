import Darwin
import Foundation

struct ProductionReplayOwnedDirectory: Sendable {
    let url: URL
    let name: String
    let parent: ProductionReplayDirectoryHandle
    let handle: ProductionReplayDirectoryHandle

    var identity: ProductionReplayParentIdentity {
        handle.identity
    }

    func fileURL(named fileName: String) -> URL {
        url.appendingPathComponent(fileName, isDirectory: false)
    }
}

private struct ProductionReplayPrivateDirectoryLocation {
    let url: URL
    let parent: ProductionReplayDirectoryHandle
    let name: String
}

extension ProductionReplayFileSystem {
    static func createPrivateDirectory(
        _ directoryURL: URL
    ) throws -> ProductionReplayOwnedDirectory {
        let location = try privateDirectoryLocation(directoryURL)
        guard mkdirat(location.parent.descriptor, location.name, 0o700) == 0
        else {
            throw ProductionReplayDriverError.privateDirectoryUnavailable
        }
        do {
            let handle = try openPrivateDirectoryComponent(
                location.name,
                parent: location.parent,
                setPrivatePermissions: true
            )
            return ProductionReplayOwnedDirectory(
                url: location.url,
                name: location.name,
                parent: location.parent,
                handle: handle
            )
        } catch {
            _ = unlinkat(
                location.parent.descriptor,
                location.name,
                AT_REMOVEDIR
            )
            throw error
        }
    }

    static func openPrivateDirectory(
        _ directoryURL: URL,
        expectedIdentity: ProductionReplayParentIdentity
    ) throws -> ProductionReplayOwnedDirectory {
        let location = try privateDirectoryLocation(directoryURL)
        let handle = try openPrivateDirectoryComponent(
            location.name,
            parent: location.parent,
            setPrivatePermissions: false
        )
        guard handle.identity == expectedIdentity else {
            throw ProductionReplayDriverError.unsafeResultParent
        }
        return ProductionReplayOwnedDirectory(
            url: location.url,
            name: location.name,
            parent: location.parent,
            handle: handle
        )
    }

    static func writeOwnedFile(
        _ data: Data,
        named name: String,
        in directory: ProductionReplayOwnedDirectory
    ) throws {
        guard isSafeComponent(name) else {
            throw ProductionReplayDriverError.invalidResultURL
        }
        try validateOwnedDirectoryPath(directory)
        try writeStagingArtifact(
            data,
            to: ProductionReplayDestination(
                finalURL: directory.fileURL(named: name),
                parentURL: directory.url,
                finalName: name,
                parent: directory.handle
            )
        )
    }

    static func readOwnedFile(
        named name: String,
        in directory: ProductionReplayOwnedDirectory,
        maxByteCount: Int
    ) throws -> Data {
        guard isSafeComponent(name), maxByteCount > 0 else {
            throw ProductionReplayDriverError.invalidResultURL
        }
        try validateOwnedDirectoryPath(directory)
        let descriptor = openat(
            directory.handle.descriptor,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
        defer { close(descriptor) }
        try validateRegularArtifact(
            descriptor: descriptor,
            parentIdentity: directory.identity
        )
        return try readAll(from: descriptor, maxByteCount: maxByteCount)
    }

    static func removeOwnedFile(
        named name: String,
        from directory: ProductionReplayOwnedDirectory
    ) throws {
        guard isSafeComponent(name) else {
            throw ProductionReplayDriverError.invalidResultURL
        }
        guard unlinkat(directory.handle.descriptor, name, 0) == 0 ||
            errno == ENOENT
        else {
            throw ProductionReplayDriverError.resultPublishFailed(errno)
        }
    }

    static func listOwnedDirectoryNames(
        _ directory: ProductionReplayOwnedDirectory
    ) throws -> [String] {
        try validateOwnedDirectoryPath(directory)
        let copiedDescriptor = dup(directory.handle.descriptor)
        guard copiedDescriptor >= 0,
              let stream = fdopendir(copiedDescriptor)
        else {
            if copiedDescriptor >= 0 {
                close(copiedDescriptor)
            }
            throw ProductionReplayDriverError.privateDirectoryUnavailable
        }
        defer { closedir(stream) }
        rewinddir(stream)

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else {
                    throw ProductionReplayDriverError
                        .privateDirectoryUnavailable
                }
                return names.sorted()
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { buffer in
                String(cString: buffer.baseAddress!
                    .assumingMemoryBound(to: CChar.self))
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
    }

    static func removeOwnedDirectory(
        _ directory: ProductionReplayOwnedDirectory
    ) throws {
        for name in try listOwnedDirectoryNames(directory) {
            var info = stat()
            guard fstatat(
                directory.handle.descriptor,
                name,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                info.st_mode & S_IFMT != S_IFDIR
            else {
                throw ProductionReplayDriverError
                    .unexpectedDirectoryEntry(name)
            }
            guard unlinkat(directory.handle.descriptor, name, 0) == 0 else {
                throw ProductionReplayDriverError.resultPublishFailed(errno)
            }
        }
        try validateOwnedDirectoryPath(directory)
        guard unlinkat(
            directory.parent.descriptor,
            directory.name,
            AT_REMOVEDIR
        ) == 0 else {
            throw ProductionReplayDriverError.resultPublishFailed(errno)
        }
    }

    static func validateOwnedDirectoryPath(
        _ directory: ProductionReplayOwnedDirectory
    ) throws {
        var info = stat()
        guard fstatat(
            directory.parent.descriptor,
            directory.name,
            &info,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            isDirectory(info),
            info.st_dev == directory.identity.device,
            info.st_ino == directory.identity.inode,
            info.st_uid == geteuid(),
            info.st_mode & 0o777 == 0o700
        else {
            throw ProductionReplayDriverError.unsafeResultParent
        }
    }

    private static func privateDirectoryLocation(
        _ directoryURL: URL
    ) throws -> ProductionReplayPrivateDirectoryLocation {
        let normalized = try normalizedFileURL(directoryURL)
        let parentURL = normalized.deletingLastPathComponent()
        let name = normalized.lastPathComponent
        guard parentURL.path != normalized.path, isSafeComponent(name) else {
            throw ProductionReplayDriverError.invalidResultURL
        }
        return try ProductionReplayPrivateDirectoryLocation(
            url: normalized,
            parent: openVerifiedParent(parentURL),
            name: name
        )
    }

    private static func openPrivateDirectoryComponent(
        _ name: String,
        parent: ProductionReplayDirectoryHandle,
        setPrivatePermissions: Bool
    ) throws -> ProductionReplayDirectoryHandle {
        let descriptor = openat(
            parent.descriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ProductionReplayDriverError.privateDirectoryUnavailable
        }
        var info = stat()
        if setPrivatePermissions, fchmod(descriptor, 0o700) != 0 {
            close(descriptor)
            throw ProductionReplayDriverError.privateDirectoryUnavailable
        }
        guard fstat(descriptor, &info) == 0,
              isDirectory(info),
              info.st_dev == parent.identity.device,
              info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o700
        else {
            close(descriptor)
            throw ProductionReplayDriverError.privateDirectoryUnavailable
        }
        return ProductionReplayDirectoryHandle(
            descriptor: descriptor,
            info: info
        )
    }
}
