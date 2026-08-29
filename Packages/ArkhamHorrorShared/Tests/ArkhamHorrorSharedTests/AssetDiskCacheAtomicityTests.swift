@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Atomic-write failure injection and restart-persistence coverage for
/// ``AssetDiskCache``, split out of `AssetDiskCacheTests.swift` (which
/// retains the shared `withScratchDirectory`/`key`/`metadata`/`smallLimits`
/// helpers) and `AssetDiskCacheQuotaTests.swift` (quota-eviction and
/// byte-accounting), purely to stay under SwiftLint's `file_length`.
extension AssetDiskCacheTests {
    // MARK: - Atomic failure injection

    @Test(
        "If the metadata write fails after the payload write succeeds, no orphaned payload remains"
    )
    func metadataWriteFailureLeavesNoOrphanPayload() async throws {
        try await withScratchDirectory { directory in
            let failingFileManager = FailingFileManager()
            failingFileManager.failPathSuffixes = [".meta.json"]
            let cache = try AssetDiskCache(
                directory: directory,
                limits: smallLimits(),
                fileManager: failingFileManager
            )
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])

            await #expect(throws: AssetError.self) {
                try await cache.set(
                    cacheKey,
                    payload: payload,
                    metadata: self.metadata(for: cacheKey, payload: payload)
                )
            }

            let payloadURL = directory.appendingPathComponent("\(cacheKey.digestHex).bin")
            #expect(
                !FileManager.default.fileExists(atPath: payloadURL.path),
                "A half-written entry (payload with no valid metadata) must not be left on disk"
            )
        }
    }

    @Test(
        "A restart (fresh actor over the same directory) still serves a previously stored entry"
    )
    func restartPersistsEntries() async throws {
        try await withScratchDirectory { directory in
            let cacheKey = try key("01001")
            let payload = Data([7, 7, 7, 7])
            do {
                let firstInstance = try AssetDiskCache(directory: directory, limits: smallLimits())
                try await firstInstance.set(
                    cacheKey,
                    payload: payload,
                    metadata: metadata(for: cacheKey, payload: payload)
                )
            }
            let secondInstance = try AssetDiskCache(directory: directory, limits: smallLimits())
            let fetched = await secondInstance.get(cacheKey)
            #expect(fetched?.payload == payload)
        }
    }

    @Test(
        "A transient directory-listing failure does not permanently disable orphan recovery"
    )
    func transientListingFailureRetriesOrphanRecoveryLater() async throws {
        try await withScratchDirectory { directory in
            let failingFileManager = FailingFileManager()
            // The very first `set` call's `recoverOrphansIfNeeded()` will
            // fail to list the directory exactly once, simulating a
            // transient I/O error rather than a permanent one.
            failingFileManager.contentsOfDirectoryFailuresRemaining = 1
            let cache = try AssetDiskCache(
                directory: directory,
                limits: smallLimits(),
                fileManager: failingFileManager
            )

            let tempURL = directory.appendingPathComponent("deadbeef.bin.tmp")
            try Data([1, 2, 3]).write(to: tempURL)

            let cacheKey = try key("01001")
            let payload = Data([9, 9, 9])
            // First `set`: recovery attempt fails (listing throws), so the
            // orphan `.tmp` file is left untouched, but the entry itself
            // still writes successfully (recovery is a best-effort side
            // step, not a precondition for `set` to work).
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )
            #expect(
                FileManager.default.fileExists(atPath: tempURL.path),
                "The orphan must still be present after a failed recovery attempt"
            )

            // Second `set`: if `didRecoverOrphans` were wrongly latched
            // `true` after the earlier failed attempt, recovery would
            // never run again and the orphan would remain forever.
            let secondKey = try key("01002")
            let secondPayload = Data([4, 4, 4])
            try await cache.set(
                secondKey,
                payload: secondPayload,
                metadata: metadata(for: secondKey, payload: secondPayload)
            )
            #expect(
                !FileManager.default.fileExists(atPath: tempURL.path),
                "A retried recovery attempt must clean up the earlier orphan"
            )
        }
    }
}

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
    /// The number of remaining `contentsOfDirectory` calls that should
    /// fail before subsequent calls succeed normally. Used to simulate a
    /// transient (not permanent) directory-listing failure.
    var contentsOfDirectoryFailuresRemaining = 0

    private func shouldFail(_ url: URL) -> Bool {
        failPathSuffixes.contains { url.path.hasSuffix($0) }
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
