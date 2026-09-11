import Darwin
import Foundation

struct ProductionReplayVerifiedPathComponent {
    let name: String
    let permitsTrustedStickyDirectory: Bool
}

extension ProductionReplayFileSystem {
    static func normalizedFileURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw ProductionReplayDriverError.invalidResultURL
        }
        return url.standardizedFileURL
    }

    static func openVerifiedParent(
        _ parentURL: URL
    ) throws -> ProductionReplayDirectoryHandle {
        let rootDescriptor = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw ProductionReplayDriverError.invalidResultParent
        }
        var currentDescriptor = rootDescriptor

        do {
            var currentInfo = try verifiedRootInfo(descriptor: rootDescriptor)
            for component in verifiedPathComponents(parentURL) {
                guard isSafeComponent(component.name) else {
                    throw ProductionReplayDriverError.invalidResultParent
                }
                let nextDescriptor = try openVerifiedComponent(
                    component.name,
                    parentDescriptor: currentDescriptor,
                    permitsTrustedStickyDirectory:
                    component.permitsTrustedStickyDirectory
                )
                close(currentDescriptor)
                currentDescriptor = nextDescriptor
                guard fstat(currentDescriptor, &currentInfo) == 0 else {
                    throw ProductionReplayDriverError.invalidResultParent
                }
            }
            guard currentInfo.st_uid == geteuid(),
                  hasSafePermissions(currentInfo)
            else {
                throw ProductionReplayDriverError.unsafeResultParent
            }
            return ProductionReplayDirectoryHandle(
                descriptor: currentDescriptor,
                info: currentInfo
            )
        } catch {
            close(currentDescriptor)
            throw error
        }
    }

    /// Rewrites only Darwin's fixed top-level compatibility aliases. Every
    /// resulting component still passes through the strict no-follow walk.
    static func verifiedPathComponents(
        _ parentURL: URL
    ) -> [ProductionReplayVerifiedPathComponent] {
        var components = parentURL.pathComponents.filter { $0 != "/" }
        var stickyDirectoryIndex: Int?
        guard let first = components.first,
              let replacement = resolvedTrustedPlatformRootAlias(first)
        else {
            return components.map {
                ProductionReplayVerifiedPathComponent(
                    name: $0,
                    permitsTrustedStickyDirectory: false
                )
            }
        }
        components.replaceSubrange(0 ... 0, with: replacement)
        if first == "tmp" {
            stickyDirectoryIndex = 1
        }
        return components.enumerated().map { index, name in
            ProductionReplayVerifiedPathComponent(
                name: name,
                permitsTrustedStickyDirectory: index == stickyDirectoryIndex
            )
        }
    }

    static func resolvedTrustedPlatformRootAlias(_ name: String) -> [String]? {
        guard ["tmp", "var", "etc"].contains(name) else { return nil }
        var info = stat()
        guard lstat("/\(name)", &info) == 0,
              info.st_mode & S_IFMT == S_IFLNK
        else {
            return nil
        }
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink("/\(name)", &buffer, buffer.count - 1)
        guard length > 0 else { return nil }
        buffer[length] = 0
        let target = buffer.withUnsafeBufferPointer {
            String(cString: $0.baseAddress!)
        }
        guard target == "private/\(name)" else { return nil }
        return ["private", name]
    }

    static func verifiedRootInfo(descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0, isDirectory(info) else {
            throw ProductionReplayDriverError.invalidResultParent
        }
        guard info.st_uid == 0, hasSafePermissions(info) else {
            throw ProductionReplayDriverError.unsafeResultParent
        }
        return info
    }

    static func openVerifiedComponent(
        _ name: String,
        parentDescriptor: Int32,
        permitsTrustedStickyDirectory: Bool
    ) throws -> Int32 {
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ProductionReplayDriverError.invalidResultParent
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, isDirectory(info) else {
            close(descriptor)
            throw ProductionReplayDriverError.invalidResultParent
        }
        let hasTrustedOwner = info.st_uid == 0 || info.st_uid == geteuid()
        let isTrustedStickyDirectory =
            permitsTrustedStickyDirectory &&
            info.st_uid == 0 &&
            info.st_mode & S_ISVTX == S_ISVTX
        guard hasTrustedOwner,
              hasSafePermissions(info) || isTrustedStickyDirectory
        else {
            close(descriptor)
            throw ProductionReplayDriverError.unsafeResultParent
        }
        return descriptor
    }

    static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty &&
            component != "." &&
            component != ".." &&
            !component.contains("/") &&
            !component.contains("\0")
    }

    static func hasSafePermissions(_ info: stat) -> Bool {
        info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    static func isDirectory(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFDIR
    }
}
