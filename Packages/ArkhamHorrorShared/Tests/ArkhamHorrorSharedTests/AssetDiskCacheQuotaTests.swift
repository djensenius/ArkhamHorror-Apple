@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Quota-eviction and byte-accounting coverage for ``AssetDiskCache``, split
/// out of `AssetDiskCacheAtomicityTests.swift` (which retains atomic-write
/// failure injection, restart persistence, and transient-failure recovery)
/// purely to stay under SwiftLint's `file_length`.
extension AssetDiskCacheTests {
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
            // mirror `AssetMemoryCacheTests`' exact-watermark scenario,
            // with `diskBudgetBytes` given extra headroom (disk-only,
            // `memoryBudgetBytes` is untouched) over that memory-only
            // scenario's value: unlike the memory cache, the disk cache
            // also durably accounts for this directory's root-authority
            // marker, clear-epoch file, and every key's own per-key
            // issuance-ticket bookkeeping files (which persist across an
            // ordinary single-entry eviction by design, see
            // `AssetDiskCache+WriteGeneration.swift`), and that fixed
            // overhead must not itself force evicting more than the one
            // truly-least-recently-used entry this test expects.
            let limits = AssetCacheLimits(
                maxEncodedBytes: 1_000_000,
                maxDimension: 8192,
                maxPixelCount: 32_000_000,
                memoryBudgetBytes: 4000,
                diskBudgetBytes: 4500,
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
            _ = try await cache.get(keyA)
            try await cache.set(
                keyC,
                payload: payloadC,
                metadata: metadata(for: keyC, payload: payloadC)
            )

            let entryA = try await cache.get(keyA)
            let entryB = try await cache.get(keyB)
            let entryC = try await cache.get(keyC)
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

    @Test(
        """
        totalAccountedBytes measures the real on-disk payload file size, not the (untrusted) \
        encodedByteCount metadata claims, so a payload substituted with something larger after \
        the fact cannot silently under-count usage against the disk quota
        """
    )
    func totalAccountedBytesUsesActualPayloadSizeNotClaimedSize() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let originalPayload = Data(count: 250)
            try await cache.set(
                cacheKey,
                payload: originalPayload,
                metadata: metadata(for: cacheKey, payload: originalPayload)
            )
            // Substitute a larger payload file on disk without touching
            // the metadata sidecar, simulating corruption/tampering/a
            // partial write after the fact: metadata still claims 250
            // bytes, but the actual file is now 900 bytes.
            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: originalPayload
            )
            try Data(count: 900).write(to: payloadURL)

            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            let metadataBytes = try #require(
                try FileManager.default.attributesOfItem(atPath: metadataURL.path)[.size] as? Int
            )
            let total = await cache.totalAccountedBytes()
            #expect(total == 900 + metadataBytes, "Must bill the real file size, not the claim")
        }
    }

    @Test(
        """
        An entry whose actual on-disk payload exceeds maxEncodedBytes is quarantined during \
        quota accounting, even though its metadata claims a small, in-budget size
        """
    )
    func oversizedActualPayloadFileQuarantinedDuringAccounting() async throws {
        try await withScratchDirectory { directory in
            let limits = AssetCacheLimits(
                maxEncodedBytes: 500,
                maxDimension: 8192,
                maxPixelCount: 32_000_000,
                memoryBudgetBytes: 1_000_000,
                diskBudgetBytes: 1_000_000
            )
            let cache = try AssetDiskCache(directory: directory, limits: limits)
            let cacheKey = try key("01001")
            let smallPayload = Data(count: 250)
            try await cache.set(
                cacheKey,
                payload: smallPayload,
                metadata: metadata(for: cacheKey, payload: smallPayload)
            )
            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: smallPayload
            )
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            // The metadata sidecar still claims 250 bytes; only the actual
            // file on disk is oversized.
            try Data(count: 600).write(to: payloadURL)

            let total = await cache.totalAccountedBytes()
            #expect(total == 0, "The oversized entry must not be counted")
            #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
        }
    }

    @Test(
        """
        Quarantining an entry whose actual on-disk payload is missing/unreadable/oversized \
        also sweeps every other stale payload generation left on disk for that same key hash, \
        not merely the one exact generation its metadata happened to reference — the same \
        crash-recovery guarantee already applied when a sidecar itself is undecodable
        """
    )
    func quarantiningUnreadablePayloadSweepsOtherStaleGenerationsForSameKeyHash() async throws {
        try await withScratchDirectory { directory in
            let limits = AssetCacheLimits(
                maxEncodedBytes: 500,
                maxDimension: 8192,
                maxPixelCount: 32_000_000,
                memoryBudgetBytes: 1_000_000,
                diskBudgetBytes: 1_000_000
            )
            let cache = try AssetDiskCache(directory: directory, limits: limits)
            let cacheKey = try key("01001")
            let smallPayload = Data(count: 250)
            try await cache.set(
                cacheKey,
                payload: smallPayload,
                metadata: metadata(for: cacheKey, payload: smallPayload)
            )
            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: smallPayload
            )
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")

            // A second, stale `.bin` generation for the exact same key
            // hash but a different (never-referenced) content hash —
            // simulating a crash between a later payload write and its
            // own metadata pointer commit, left behind after the
            // once-per-instance startup orphan sweep already ran.
            let staleGenerationURL = directory
                .appendingPathComponent("\(cacheKey.digestHex).deadbeefstale.bin")
            try Data(count: 10).write(to: staleGenerationURL)

            // The metadata sidecar still claims 250 bytes; only the
            // actual referenced payload file on disk is oversized, which
            // is what triggers this entry's own quarantine.
            try Data(count: 600).write(to: payloadURL)

            let total = await cache.totalAccountedBytes()
            #expect(total == 0, "The oversized entry must not be counted")
            #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
            #expect(
                !FileManager.default.fileExists(atPath: staleGenerationURL.path),
                "A stale sibling generation for the same key hash must not survive quarantine"
            )
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

            try await cache.remove(cacheKey)
            let fetched = try await cache.get(cacheKey)
            #expect(fetched == nil)
            // Excludes the cache's own reserved cross-process lock file,
            // durable root-authority-initialization marker, durable
            // clear-epoch counter, and this exact key's own durable
            // disk-write-generation counters (`<hash>.gen`/`<hash>.applied`,
            // see `AssetDiskCache+WriteGeneration.swift`): unlike the
            // payload/metadata pair a removal is actually responsible for
            // deleting, those counters are deliberately never removed by an
            // ordinary per-key `remove(_:token:)` -- see that file's own
            // doc comment for why letting them survive an ordinary removal
            // (while still being fully reset by a whole-cache
            // `removeAll()`) is required to keep a stale, still-in-flight
            // write for this exact key from being able to resurrect
            // content after this legitimate removal.
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter {
                    $0 != SecureCacheDirectory.lockFileName
                        && $0 != SecureCacheDirectory.accessSequenceFileName
                        && $0 != SecureCacheDirectory.clearEpochFileName
                        && $0 != SecureCacheDirectory.rootInitMarkerFileName
                        && $0 != "\(cacheKey.digestHex).gen"
                        && $0 != "\(cacheKey.digestHex).applied"
                }
            #expect(contents.isEmpty)
        }
    }
}
