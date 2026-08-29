@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Atomic-write failure injection and restart-persistence coverage for
/// ``AssetDiskCache``, split out of `AssetDiskCacheTests.swift` (which
/// retains the shared `withScratchDirectory`/`key`/`metadata`/`smallLimits`
/// helpers, along with quota-eviction and byte-accounting tests) purely to
/// stay under SwiftLint's `file_length`.
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

    // MARK: - Quota eviction

    @Test(
        "Inserting past the high water mark evicts the LRU entry down to the low mark"
    )
    func evictsLeastRecentlyAccessedEntryAtQuota() async throws {
        try await withScratchDirectory { directory in
            // Each entry accounts for its 1000-byte payload plus the real
            // on-disk size of its metadata sidecar (a few hundred bytes,
            // for this schema and these short URLs), which the assertions
            // below only depend on being large enough to be non-negligible
            // relative to the payload — the exact eviction/survival
            // outcome does not depend on its precise value. Budget/ratios
            // mirror `AssetMemoryCacheTests`' exact-watermark scenario.
            let limits = AssetCacheLimits(
                maxEncodedBytes: 1_000_000,
                maxDimension: 8192,
                maxPixelCount: 32_000_000,
                memoryBudgetBytes: 4000,
                diskBudgetBytes: 4000,
                highWaterMarkRatio: 0.95,
                lowWaterMarkRatio: 0.76
            )
            let cache = try AssetDiskCache(directory: directory, limits: limits)
            let keyA = try key("01001")
            let keyB = try key("01002")
            let keyC = try key("01003")
            let payloadA = Data(count: 1000)
            let payloadB = Data(count: 1000)
            let payloadC = Data(count: 1000)

            try await cache.set(
                keyA,
                payload: payloadA,
                metadata: metadata(for: keyA, payload: payloadA, at: Date().addingTimeInterval(-10))
            )
            try await cache.set(
                keyB,
                payload: payloadB,
                metadata: metadata(for: keyB, payload: payloadB, at: Date().addingTimeInterval(-5))
            )
            // Re-access A so it is more-recently-used than B at the moment C is inserted.
            _ = await cache.get(keyA)
            try await cache.set(
                keyC,
                payload: payloadC,
                metadata: metadata(for: keyC, payload: payloadC)
            )

            let entryA = await cache.get(keyA)
            let entryB = await cache.get(keyB)
            let entryC = await cache.get(keyC)
            #expect(entryB == nil, "B was least-recently-used and should have been evicted")
            #expect(entryA != nil, "A was re-accessed before C's insertion and must survive")
            #expect(entryC != nil, "C was just inserted and must survive eviction")
        }
    }

    @Test(
        "totalAccountedBytes reflects exactly payload plus the metadata sidecar's real disk size"
    )
    func totalAccountedBytesIsExact() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data(count: 250)
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            let metadataBytes = try #require(
                try FileManager.default.attributesOfItem(atPath: metadataURL.path)[.size] as? Int
            )
            let total = await cache.totalAccountedBytes()
            #expect(total == 250 + metadataBytes)
            // A guard against this test becoming vacuous if some future
            // change made the metadata sidecar implausibly tiny: the fixed
            // estimate this used to compare against remains a reasonable
            // lower bound on real serialized metadata size.
            #expect(metadataBytes > 100)
        }
    }

    @Test("Removing a key deletes both its payload and metadata files")
    func removeDeletesBothFiles() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            await cache.remove(cacheKey)
            let fetched = await cache.get(cacheKey)
            #expect(fetched == nil)
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(contents.isEmpty)
        }
    }

    @Test(
        """
        A corrupt (undecodable) metadata sidecar found during quota accounting is quarantined \
        immediately, not merely skipped, so it cannot occupy disk space indefinitely uncounted
        """
    )
    func undecodableEntryEncounteredDuringAccountingIsQuarantined() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            let payloadURL = directory.appendingPathComponent("\(cacheKey.digestHex).bin")
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            try Data("not json".utf8).write(to: metadataURL)

            // totalAccountedBytes() walks every entry via the same
            // internal accounting path evictIfNeeded() uses; it must not
            // count (and must actively remove) an entry whose sidecar
            // cannot be decoded.
            let total = await cache.totalAccountedBytes()
            #expect(total == 0)
            #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
        }
    }

    @Test(
        """
        An entry whose metadata cacheKeyHex does not match its own filename hash is quarantined \
        during quota accounting rather than silently skipped
        """
    )
    func mismatchedCacheKeyHexEncounteredDuringAccountingIsQuarantined() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            let payloadURL = directory.appendingPathComponent("\(cacheKey.digestHex).bin")
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            var json = try #require(
                try JSONSerialization
                    .jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
            )
            json["cacheKeyHex"] = "0000000000000000000000000000000000000000000000000000000000000000"
            let tampered = try JSONSerialization.data(withJSONObject: json)
            try tampered.write(to: metadataURL)

            let total = await cache.totalAccountedBytes()
            #expect(total == 0)
            #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
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
