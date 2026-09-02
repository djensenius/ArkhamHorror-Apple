@testable import ArkhamHorrorShared
import Darwin
import Foundation
import Testing

/// Proves the owner/permission/device policy
/// ``SecureCacheDirectory/requireTrustedAncestor(info:name:trustedOwnerUID:)``
/// and `SecureCacheDirectory.openVerifiedComponent(...)` enforce at every
/// step of the path walk (not merely the final leaf entry),
/// and that ``SecureCacheDirectory/attributes(name:)`` shares the exact same
/// regular-file/owner/device/link-count policy
/// ``SecureCacheDirectory/read(name:maxBytes:)`` already enforced, closing
/// the gap where a hardlinked or cross-device file could previously pass
/// `attributes(name:)`'s looser check even though a real read of it would
/// have been rejected.
@Suite("SecureCacheDirectory owner/permission/device policy")
struct SecureCacheDirectorySecurityPolicyTests {
    private func withScratchDirectory(
        _ body: (_ base: URL) throws -> Void
    ) throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("SecurityPolicyScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        // This suite exercises `openVerifiedComponent(...)` directly
        // against a raw `open(2)`-obtained parent descriptor -- never
        // through `SecureCacheDirectory.init`'s own walk -- so, unlike
        // every other suite's `withScratchDirectory`, this directory
        // must already exist before `body` runs.
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(base)
    }

    /// Builds a minimal, otherwise-valid `stat` value so the pure
    /// owner/permission predicate can be exercised deterministically --
    /// without needing actual root privileges (unavailable in a normal
    /// test environment) to plant a genuinely different-owner directory
    /// on disk.
    private func fakeDirectoryStat(uid: uid_t, mode: mode_t) -> stat {
        var info = stat()
        info.st_mode = S_IFDIR | mode
        info.st_uid = uid
        return info
    }

    @Test("A component owned by neither root nor the current process's uid is rejected")
    func rejectsUntrustedOwner() {
        let attackerInfo = fakeDirectoryStat(uid: getuid() + 12345, mode: 0o755)
        #expect(throws: AssetError.self) {
            try SecureCacheDirectory.requireTrustedAncestor(
                info: attackerInfo,
                name: "attacker-owned",
                trustedOwnerUID: getuid()
            )
        }
    }

    @Test("A root-owned component is tolerated (a pre-existing, OS-managed ancestor)")
    func toleratesRootOwner() throws {
        let rootInfo = fakeDirectoryStat(uid: 0, mode: 0o755)
        try SecureCacheDirectory.requireTrustedAncestor(
            info: rootInfo,
            name: "root-owned",
            trustedOwnerUID: getuid()
        )
    }

    @Test("A component owned by the current process's own uid is tolerated")
    func toleratesOwnUID() throws {
        let ownInfo = fakeDirectoryStat(uid: getuid(), mode: 0o700)
        try SecureCacheDirectory.requireTrustedAncestor(
            info: ownInfo,
            name: "own-uid",
            trustedOwnerUID: getuid()
        )
    }

    @Test("A world-writable component is rejected even when root-owned")
    func rejectsWorldWritableRegardlessOfOwner() {
        let worldWritableInfo = fakeDirectoryStat(uid: 0, mode: 0o777)
        #expect(throws: AssetError.self) {
            try SecureCacheDirectory.requireTrustedAncestor(
                info: worldWritableInfo,
                name: "world-writable",
                trustedOwnerUID: getuid()
            )
        }
    }

    @Test("An intermediate component on an unexpected device is rejected, not only the final leaf")
    func rejectsDeviceMismatchMidWalk() throws {
        try withScratchDirectory { base in
            let rootFD = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            #expect(rootFD >= 0)
            defer { close(rootFD) }
            // No real second device is available in a hosted test
            // environment, so a value that can never legitimately match
            // any real `st_dev` proves the check is actually applied
            // (rather than merely accepted as a no-op) without requiring
            // an actual mounted volume.
            #expect(throws: AssetError.self) {
                let descriptor = try SecureCacheDirectory.openVerifiedComponent(
                    parentFD: rootFD,
                    name: "nested",
                    createIfMissing: true,
                    expectedDevice: dev_t.max,
                    trustedOwnerUID: getuid()
                ).descriptor
                close(descriptor)
            }
        }
    }

    @Test(
        """
        A component matching the expected device and owned by the current process's uid \
        is accepted, proving the new checks do not merely always reject
        """
    )
    func acceptsExpectedDeviceAndOwner() throws {
        try withScratchDirectory { base in
            let rootFD = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            #expect(rootFD >= 0)
            defer { close(rootFD) }
            var rootInfo = stat()
            #expect(fstat(rootFD, &rootInfo) == 0)
            let descriptor = try SecureCacheDirectory.openVerifiedComponent(
                parentFD: rootFD,
                name: "nested",
                createIfMissing: true,
                expectedDevice: rootInfo.st_dev,
                trustedOwnerUID: getuid()
            ).descriptor
            close(descriptor)
        }
    }

    @Test(
        """
        attributes(name:) reports a hardlinked file (sharing another entry's inode) as not a \
        verified regular file, exactly like a direct read of it is already rejected -- a \
        caller relying only on attributes(name:)'s looser prior check (no st_dev/st_nlink \
        verification) could previously be misled into treating externally-hardlinked bytes as \
        this cache's own
        """
    )
    func attributesRejectsHardlinkedFile() throws {
        try withScratchDirectory { base in
            let directory = try SecureCacheDirectory(directory: base, fileManager: .default)
            let originalPath = base.appendingPathComponent("original.bin").path
            try Data("hello".utf8).write(to: URL(fileURLWithPath: originalPath))
            let hardlinkName = "hardlinked.bin"
            let hardlinkPath = base.appendingPathComponent(hardlinkName).path
            #expect(link(originalPath, hardlinkPath) == 0)

            let attributes = try directory.attributes(name: hardlinkName)
            #expect(attributes != nil)
            #expect(
                attributes?.isRegularFile == false,
                """
                A hardlinked file (st_nlink > 1) must never be reported as a verified regular \
                file by attributes(name:)
                """
            )
        }
    }

    @Test(
        "attributes(name:) still reports an ordinary, single-link cache-owned file as verified"
    )
    func attributesAcceptsOrdinaryFile() throws {
        try withScratchDirectory { base in
            let directory = try SecureCacheDirectory(directory: base, fileManager: .default)
            let name = "ordinary.bin"
            let path = base.appendingPathComponent(name).path
            try Data("hello".utf8).write(to: URL(fileURLWithPath: path))

            let attributes = try directory.attributes(name: name)
            #expect(attributes?.isRegularFile == true)
        }
    }
}
