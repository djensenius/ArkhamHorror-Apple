@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for a persistently-unremovable orphan/temp file's bytes being
/// counted toward the disk quota — and cleanup being retried on every
/// subsequent write rather than only once at process startup — split out
/// of `AssetDiskCacheQuotaTests.swift` purely to stay under SwiftLint's
/// `file_length`.
extension AssetDiskCacheTests {
    /// A stray `.bin` file that no metadata sidecar will ever reference
    /// (its name matches the general payload naming convention closely
    /// enough to be realistic, but its content-hash component is
    /// deliberately never one any entry actually has), simulating e.g. a
    /// crash-orphaned generation that happens to sit on a
    /// transiently-read-only filesystem. Also installs fault injection so
    /// its removal always fails, and returns the name so a test can
    /// assert on/clear that fault later.
    func writeUnremovableOrphan(in directory: URL, cache: AssetDiskCache) async throws -> String {
        let orphanName = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" +
            ".orphanedgenerationneverreferenced.bin"
        try Data(count: 2000).write(to: directory.appendingPathComponent(orphanName))
        await cache.directoryAccess.installFaultInjection(failRemoveSuffixes: [orphanName])
        return orphanName
    }

    /// Deliberately small, explicit water marks (mirroring
    /// `evictsLeastRecentlyAccessedEntryAtQuota`'s style): tight enough
    /// that a 2000-byte stranded orphan alone pushes total usage over
    /// `highWaterMarkDiskBytes`, while a single tracked entry is tiny by
    /// comparison — so the *only* way eviction can trigger at all is if
    /// the orphan's bytes are actually being counted.
    func orphanQuotaTestLimits() -> AssetCacheLimits {
        AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1_000_000,
            diskBudgetBytes: 3000,
            highWaterMarkRatio: 0.6,
            lowWaterMarkRatio: 0.3
        )
    }

    @Test(
        """
        A persistently unremovable orphan .bin file's bytes are counted toward the disk quota, \
        forcing eviction of an otherwise still-recent, in-budget tracked entry, rather than \
        letting stranded bytes silently grow the cache beyond its configured budget
        """
    )
    func persistentlyUnremovableOrphanBytesCountTowardQuotaAndForceEviction() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: orphanQuotaTestLimits())
            let orphanName = try await writeUnremovableOrphan(in: directory, cache: cache)

            let cacheKey = try key("01001")
            let payload = Data(count: 100)
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            #expect(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(orphanName).path
                ),
                "The orphan's removal was fault-injected to fail and must still be present"
            )
            let fetched = await cache.get(cacheKey)
            #expect(
                fetched == nil,
                """
                The freshly-inserted entry must have been evicted immediately: its own bytes \
                alone are far under highWaterMarkDiskBytes, so eviction can only have triggered \
                if the persistently-stranded orphan's 2000 bytes were folded into the total
                """
            )
        }
    }

    @Test(
        """
        Once a previously-unremovable orphan's removal stops failing, the next write retries \
        cleanup and reclaims it, rather than treating the earlier failed attempt as permanently \
        given up on — and a fresh entry can then survive normally again
        """
    )
    func clearedOrphanFaultIsReclaimedOnNextWrite() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: orphanQuotaTestLimits())
            let orphanName = try await writeUnremovableOrphan(in: directory, cache: cache)
            let firstKey = try key("01001")
            let firstPayload = Data(count: 100)
            try await cache.set(
                firstKey,
                payload: firstPayload,
                metadata: metadata(for: firstKey, payload: firstPayload)
            )

            // Clearing the fault and writing again must retry cleanup —
            // not treat the earlier failed attempt as permanently given
            // up on — and, once the orphan is actually reclaimed, a fresh
            // entry must survive normally again.
            await cache.directoryAccess.installFaultInjection()
            let secondKey = try key("01002")
            let secondPayload = Data(count: 100)
            try await cache.set(
                secondKey,
                payload: secondPayload,
                metadata: metadata(for: secondKey, payload: secondPayload)
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(orphanName).path
                ),
                "A retried sweep must reclaim the orphan once its removal no longer fails"
            )
            let secondFetched = await cache.get(secondKey)
            #expect(
                secondFetched != nil,
                "Once the stranded orphan is actually reclaimed, a fresh entry must survive"
            )
        }
    }
}
