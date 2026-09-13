import Darwin
import Foundation

extension ProductionReplayFileSystem {
    static func validatePublishedArtifact(
        _ destination: ProductionReplayDestination
    ) throws {
        var info = stat()
        guard fstatat(
            destination.parent.descriptor,
            destination.finalName,
            &info,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            isRegular(info),
            info.st_dev == destination.parent.identity.device,
            info.st_uid == geteuid(),
            info.st_nlink == 1
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
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
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              isRegular(info),
              info.st_dev == parentIdentity.device,
              info.st_uid == geteuid(),
              info.st_nlink == 1
        else {
            throw ProductionReplayDriverError.resultMissingOrNotRegular
        }
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
}
