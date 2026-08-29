import Foundation

/// A `FileManager` subclass that injects a deterministic failure into the
/// final rename step (`moveItem`) for paths whose name ends in any of
/// `failPathSuffixes`, leaving every other filesystem operation (including
/// the *payload's* own atomic write) untouched.
///
/// This exercises ``AssetDiskCache``'s atomic-write failure-recovery path
/// with a real, precisely-targeted filesystem failure, rather than a
/// fragile permissions/filesystem-layout trick that risks failing (or
/// succeeding) for reasons unrelated to the code path under test.
/// Not `private`: also reused by ``AssetCacheServiceTests``'s
/// disk-persistence-failure coverage (in
/// `AssetCacheServicePersistenceTests.swift`) to simulate a real,
/// precisely-targeted filesystem failure without a fragile
/// permissions/filesystem-layout trick.
final class FailingFileManager: FileManager, @unchecked Sendable {
    var failPathSuffixes: Set<String> = []
    /// Matched against a candidate URL's last path component via
    /// `hasPrefix`, rather than the whole path via `hasSuffix` above.
    /// Needed to target "any payload generation for this cache key"
    /// under the content-addressed `<keyHash>.<contentHash>.bin` payload
    /// naming scheme, where the content hash (and therefore the exact
    /// suffix) is not known ahead of a write.
    var failPathPrefixes: Set<String> = []
    /// The number of remaining `contentsOfDirectory` calls that should
    /// fail before subsequent calls succeed normally. Used to simulate a
    /// transient (not permanent) directory-listing failure.
    var contentsOfDirectoryFailuresRemaining = 0
    /// Every successful or failed `contentsOfDirectory` call increments
    /// this, regardless of `contentsOfDirectoryFailuresRemaining`. Used to
    /// prove a clean cache miss never triggers a directory listing.
    var contentsOfDirectoryCallCount = 0

    private func shouldFail(_ url: URL) -> Bool {
        failPathSuffixes.contains { url.path.hasSuffix($0) }
            || failPathPrefixes.contains { url.lastPathComponent.hasPrefix($0) }
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if shouldFail(dstURL) {
            throw NSError(domain: "FailingFileManagerTest", code: 1)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        contentsOfDirectoryCallCount += 1
        if contentsOfDirectoryFailuresRemaining > 0 {
            contentsOfDirectoryFailuresRemaining -= 1
            throw NSError(domain: "FailingFileManagerTest", code: 2)
        }
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }
}
