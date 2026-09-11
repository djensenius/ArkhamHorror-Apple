import Darwin
import Foundation

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
            for component in parentURL.pathComponents.dropFirst() {
                guard isSafeComponent(component) else {
                    throw ProductionReplayDriverError.invalidResultParent
                }
                let nextDescriptor = try openVerifiedComponent(
                    component,
                    parentDescriptor: currentDescriptor
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
        parentDescriptor: Int32
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
        guard info.st_uid == 0 || info.st_uid == geteuid(),
              hasSafePermissions(info)
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
