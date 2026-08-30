@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for an invalid/corrupt/undecodable metadata sidecar (a
/// `.meta.json` file `entries(names:)` attempts, and fails, to quarantine)
/// still being counted toward the disk quota — never silently excluded
/// merely because ``AssetDiskCache/accountedStrayCacheFileBytes(names:)``
/// otherwise always assumes every `.meta.json`-suffixed file is already
/// fully accounted for by that same method's own valid-entry result. Split
/// out of `AssetDiskCacheQuotaTests.swift`/`AssetDiskCacheOrphanQuotaTests.swift`
/// purely to stay under SwiftLint's `file_length`, mirroring the latter's
/// own unremovable-orphan coverage for the `.bin`/`.tmp` side of the same
/// concern.
extension AssetDiskCacheTests {
    /// A structurally corrupt (undecodable-as-JSON) `.meta.json` sidecar
    /// for a key hash that never has any corresponding valid entry,
    /// simulating e.g. a crash-truncated metadata write that happens to
    /// sit on a transiently-read-only filesystem. Also installs fault
    /// injection so its removal always fails, and returns the name so a
    /// test can assert on/clear that fault later.
    func writeUnremovableCorruptSidecar(
        in directory: URL,
        cache: AssetDiskCache,
        contentByteCount: Int = 2000
    ) async throws -> String {
        let hash = String(repeating: "a", count: 64)
        let sidecarName = "\(hash).meta.json"
        // Not valid JSON at all -- guaranteed undecodable, taking the
        // exact same quarantine path as a genuinely truncated/corrupted
        // write would.
        try Data(count: contentByteCount).write(to: directory.appendingPathComponent(sidecarName))
        await cache.directoryAccess.installFaultInjection(failRemoveSuffixes: [sidecarName])
        return sidecarName
    }

    /// Deliberately small, explicit water marks, mirroring
    /// `AssetDiskCacheOrphanQuotaTests.orphanQuotaTestLimits()`'s own
    /// style: tight enough that a 2000-byte stranded sidecar alone pushes
    /// total usage over `highWaterMarkDiskBytes`, while a single tracked
    /// entry is tiny by comparison -- so the *only* way eviction can
    /// trigger at all is if the stranded sidecar's bytes are actually
    /// being counted.
    func invalidSidecarQuotaTestLimits() -> AssetCacheLimits {
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
        A persistently unremovable invalid metadata sidecar's bytes are counted toward the disk \
        quota, forcing eviction of an otherwise still-recent, in-budget tracked entry, rather \
        than letting stranded bytes silently grow the cache beyond its configured budget merely \
        because they belong to a ".meta.json"-suffixed file
        """
    )
    func persistentlyUnremovableInvalidSidecarBytesCountTowardQuotaAndForceEviction() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(
                directory: directory,
                limits: invalidSidecarQuotaTestLimits()
            )
            let sidecarName = try await writeUnremovableCorruptSidecar(
                in: directory,
                cache: cache
            )

            let cacheKey = try key("01001")
            let payload = Data(count: 100)
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            #expect(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(sidecarName).path
                ),
                "The sidecar's removal was fault-injected to fail and must still be present"
            )
            let fetched = try await cache.get(cacheKey)
            #expect(
                fetched == nil,
                """
                The freshly-inserted entry must have been evicted immediately: its own bytes \
                alone are far under highWaterMarkDiskBytes, so eviction can only have triggered \
                if the persistently-stranded invalid sidecar's 2000 bytes were folded into the \
                total
                """
            )
        }
    }

    @Test(
        """
        Once a previously-unremovable invalid sidecar's removal stops failing, the next write \
        retries cleanup and reclaims it, rather than treating the earlier failed attempt as \
        permanently given up on -- and a fresh entry can then survive normally again
        """
    )
    func clearedInvalidSidecarFaultIsReclaimedOnNextWrite() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(
                directory: directory,
                limits: invalidSidecarQuotaTestLimits()
            )
            let sidecarName = try await writeUnremovableCorruptSidecar(
                in: directory,
                cache: cache
            )
            let firstKey = try key("01001")
            let firstPayload = Data(count: 100)
            try await cache.set(
                firstKey,
                payload: firstPayload,
                metadata: metadata(for: firstKey, payload: firstPayload)
            )

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
                    atPath: directory.appendingPathComponent(sidecarName).path
                ),
                """
                A retried quarantine attempt must reclaim the sidecar once its removal no \
                longer fails
                """
            )
            let secondFetched = try await cache.get(secondKey)
            #expect(
                secondFetched != nil,
                "Once the stranded sidecar is actually reclaimed, a fresh entry must survive"
            )
        }
    }

    @Test(
        """
        An invalid metadata sidecar whose removal fails *and* whose own post-removal physical \
        size cannot even be determined (a genuine fstatat failure, not merely "file is gone") \
        disables new disk writes exactly like an unenumerable directory listing -- physical \
        usage is not merely "a bit higher than expected", it is unknown, and must never be \
        silently treated as zero extra bytes
        """
    )
    func unremovableInvalidSidecarWithUnreadableSizeDisablesWrites() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(
                directory: directory,
                limits: invalidSidecarQuotaTestLimits()
            )
            let sidecarName = try await writeUnremovableCorruptSidecar(
                in: directory,
                cache: cache
            )
            // Both the removal attempt itself *and* the post-removal
            // attributes re-check must fail here, simulating a genuine
            // `fstatat` failure (permission/I/O) on this exact stray file
            // -- as opposed to the removal simply not having reclaimed
            // it, which the tests above already cover.
            await cache.directoryAccess.installFaultInjection(
                failRemoveSuffixes: [sidecarName],
                failAttributesSuffixes: [sidecarName]
            )

            // This write's own trailing `evictIfNeeded()` pass is the one
            // that actually encounters the unreadable stranded sidecar
            // and marks writes disabled -- the call that triggers it
            // still succeeds normally (the failure only affects *future*
            // writes' own pre-write gate).
            let firstKey = try key("01001")
            let firstPayload = Data(count: 100)
            try await cache.set(
                firstKey,
                payload: firstPayload,
                metadata: metadata(for: firstKey, payload: firstPayload)
            )

            let secondKey = try key("01002")
            let secondPayload = Data(count: 100)
            await #expect(throws: (any Error).self) {
                try await cache.set(
                    secondKey,
                    payload: secondPayload,
                    metadata: metadata(for: secondKey, payload: secondPayload)
                )
            }
        }
    }
}
