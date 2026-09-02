@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves ``SecureCacheDirectory``'s documented symlink-safety contract
/// against a real filesystem: an attacker (or a confused prior process)
/// planting a symlink at a cache entry's exact name, pointing outside the
/// verified cache root, is refused (`O_NOFOLLOW`/`AT_SYMLINK_NOFOLLOW`
/// fail closed) rather than silently followed — and, critically, the
/// external target the symlink points to is never read, written, or
/// removed as a side effect of any operation against the entry name.
@Suite("SecureCacheDirectory symlink safety")
struct SecureCacheDirectorySymlinkSafetyTests {
    private func withRoots(
        _ body: (_ cacheRoot: URL, _ outsideRoot: URL) async throws -> Void
    ) async throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("SymlinkSafetyScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheRoot = base.appendingPathComponent("cache", isDirectory: true)
        let outsideRoot = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try await body(cacheRoot, outsideRoot)
    }

    @Test(
        "A symlink planted at an entry name pointing outside the cache root is never read through"
    )
    func symlinkEntryNeverReadThrough() async throws {
        try await withRoots { cacheRoot, outsideRoot in
            let secretFile = outsideRoot.appendingPathComponent("secret")
            let secretContent = Data("top secret, outside the cache root".utf8)
            try secretContent.write(to: secretFile)

            let directory = try SecureCacheDirectory(
                directory: cacheRoot,
                fileManager: .default
            )
            let entryName = "planted-symlink"
            try FileManager.default.createSymbolicLink(
                at: cacheRoot.appendingPathComponent(entryName),
                withDestinationURL: secretFile
            )

            #expect(throws: AssetError.self) {
                _ = try directory.read(name: entryName, maxBytes: 16384)
            }
            // The external target itself must be entirely untouched by the
            // attempted (and refused) read.
            let stillThere = try Data(contentsOf: secretFile)
            #expect(stillThere == secretContent)
        }
    }

    @Test("attributes(name:) reports a symlinked entry as not a verified regular file")
    func symlinkEntryAttributesRefused() async throws {
        try await withRoots { cacheRoot, outsideRoot in
            let target = outsideRoot.appendingPathComponent("target")
            try Data("some bytes".utf8).write(to: target)

            let directory = try SecureCacheDirectory(directory: cacheRoot, fileManager: .default)
            let entryName = "planted-symlink"
            try FileManager.default.createSymbolicLink(
                at: cacheRoot.appendingPathComponent(entryName),
                withDestinationURL: target
            )

            // `fstatat` with `AT_SYMLINK_NOFOLLOW` succeeds (reporting the
            // symlink's own stat, never the target's) rather than
            // throwing, but must never report it as a verified regular
            // file — callers (``AssetDiskCache``) treat `isRegularFile ==
            // false` identically to a corrupt/untrusted entry.
            let attributes = try directory.attributes(name: entryName)
            #expect(attributes?.isRegularFile == false)
        }
    }

    @Test(
        """
        Removing a symlinked entry name only unlinks the symlink itself (never traverses to \
        or deletes the external target), matching unlink(2)'s own non-following semantics
        """
    )
    func removingSymlinkEntryNeverRemovesExternalTarget() async throws {
        try await withRoots { cacheRoot, outsideRoot in
            let target = outsideRoot.appendingPathComponent("target")
            try Data("some bytes".utf8).write(to: target)

            let directory = try SecureCacheDirectory(directory: cacheRoot, fileManager: .default)
            let entryName = "planted-symlink"
            try FileManager.default.createSymbolicLink(
                at: cacheRoot.appendingPathComponent(entryName),
                withDestinationURL: target
            )

            let removed = try directory.remove(name: entryName)
            #expect(removed)
            #expect(FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test(
        """
        A cache root whose original path is later replaced by an attacker (moved aside, with a \
        different directory put in its place) never redirects this instance's operations to \
        that new directory: every call keeps resolving against the exact descriptor opened and \
        verified at construction time, never a fresh path lookup
        """
    )
    func rootDirectoryReplacementAfterInitDoesNotRedirectOperations() async throws {
        try await withRoots { cacheRoot, _ in
            let directory = try SecureCacheDirectory(directory: cacheRoot, fileManager: .default)
            try directory.writeTempAndFsync(tempName: "entry.tmp", data: Data("v1".utf8))
            try directory.renameAndFsyncDirectory(from: "entry.tmp", to: "entry")

            // Attacker: move the original (legitimate) directory aside,
            // then put a brand new directory with attacker-controlled
            // content at the exact original path.
            let movedAside = cacheRoot.deletingLastPathComponent()
                .appendingPathComponent("moved-aside", isDirectory: true)
            try FileManager.default.moveItem(at: cacheRoot, to: movedAside)
            try FileManager.default.createDirectory(
                at: cacheRoot,
                withIntermediateDirectories: true
            )
            try Data("attacker-content".utf8).write(
                to: cacheRoot.appendingPathComponent("entry")
            )

            // This instance's descriptor still refers to the original,
            // legitimate directory (now living only at `movedAside` in
            // the filesystem namespace, but still open via its
            // descriptor) — never the new, attacker-planted directory
            // that now occupies the original path.
            let stillReadable = try directory.read(name: "entry", maxBytes: 100)
            #expect(stillReadable == Data("v1".utf8))
        }
    }

    @Test(
        """
        A symlink planted at an intermediate path component between the filesystem and the \
        cache root's own leaf directory — not the leaf itself — is refused at construction \
        rather than silently traversed into its target
        """
    )
    func intermediateComponentSymlinkRefusedAtConstruction() async throws {
        try await withRoots { cacheRoot, outsideRoot in
            // `cacheRoot` is `.../<uuid>/cache`; replace its *parent*
            // component with a symlink pointing at `outsideRoot`, so a
            // naive path-string-based directory creation (which
            // `FileManager.createDirectory(at:withIntermediateDirectories:)`
            // would happily do) would transparently create/use
            // `outsideRoot/cache` instead of ever failing.
            let parent = cacheRoot.deletingLastPathComponent()
            try FileManager.default.removeItem(at: parent)
            try FileManager.default.createSymbolicLink(
                at: parent,
                withDestinationURL: outsideRoot
            )

            #expect(throws: AssetError.self) {
                _ = try SecureCacheDirectory(directory: cacheRoot, fileManager: .default)
            }
            // The symlink's target must never have had a `cache`
            // subdirectory created inside it as a side effect of the
            // refused attempt.
            #expect(
                !FileManager.default.fileExists(
                    atPath: outsideRoot.appendingPathComponent("cache").path
                )
            )
        }
    }

    @Test("A hardlinked entry sharing another file's inode is refused as an untrusted regular file")
    func hardlinkedEntryRefused() async throws {
        try await withRoots { cacheRoot, outsideRoot in
            let directory = try SecureCacheDirectory(directory: cacheRoot, fileManager: .default)
            try directory.writeTempAndFsync(tempName: "entry.tmp", data: Data("v1".utf8))
            try directory.renameAndFsyncDirectory(from: "entry.tmp", to: "entry")

            let entryPath = cacheRoot.appendingPathComponent("entry").path
            let hardlinkPath = outsideRoot.appendingPathComponent("hardlink").path
            guard link(entryPath, hardlinkPath) == 0 else {
                // Hardlinks across the two directories used by this test
                // (both created under this same scratch tree, so
                // ordinarily the same device) are expected to succeed;
                // if the test environment cannot create one here (e.g. a
                // filesystem that disallows hardlinks at this location),
                // there is nothing further this specific test can prove.
                return
            }

            #expect(throws: AssetError.self) {
                _ = try directory.read(name: "entry", maxBytes: 100)
            }
        }
    }
}
