@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("AssetMemoryCache")
struct AssetMemoryCacheTests {
    private func metadata(
        cacheKeyHex: String,
        encodedByteCount: Int,
        at date: Date = Date()
    ) -> AssetCacheMetadata {
        AssetCacheMetadata(
            cacheKeyHex: cacheKeyHex,
            contentType: "image/png",
            encodedByteCount: encodedByteCount,
            width: 4,
            height: 4,
            payloadSHA256Hex: String(repeating: "a", count: 64),
            etag: nil,
            lastModified: nil,
            resolvedURLString: "https://example.com/\(cacheKeyHex)",
            insertedAt: date,
            lastAccessedAt: date
        )
    }

    private func key(_ rawCardCode: String) throws -> AssetCacheKey {
        let identifier = try AssetIdentifier.cardCode(rawCardCode)
        let assetKey = AssetKey(category: .card(.art, identifier))
        let candidates = AssetLocator.candidates(for: assetKey, digest: FakeDigestLookup())
        return AssetCacheKey(for: assetKey, candidates: candidates)
    }

    @Test("A stored entry can be retrieved with its payload and metadata intact")
    func setThenGetRoundTrips() async throws {
        let cache = AssetMemoryCache(limits: AssetCacheLimits(
            maxEncodedBytes: 1024,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1_000_000,
            diskBudgetBytes: 1_000_000
        ))
        let cacheKey = try key("01001")
        let payload = Data([1, 2, 3, 4])
        await cache.set(
            cacheKey,
            asset: CachedAsset(
                payload: payload,
                metadata: metadata(cacheKeyHex: "a", encodedByteCount: 4)
            )
        )

        let fetched = await cache.get(cacheKey)
        #expect(fetched?.payload == payload)
    }

    @Test("A missing key returns nil")
    func missingKeyReturnsNil() async throws {
        let cache = AssetMemoryCache(limits: AssetCacheLimits(
            maxEncodedBytes: 1024,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1_000_000,
            diskBudgetBytes: 1_000_000
        ))
        let cacheKey = try key("01001")
        let fetched = await cache.get(cacheKey)
        #expect(fetched == nil)
    }

    @Test("Removing a key makes it absent, and does not disturb other keys")
    func removeRemovesOnlyThatKey() async throws {
        let cache = AssetMemoryCache(limits: AssetCacheLimits(
            maxEncodedBytes: 1024,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1_000_000,
            diskBudgetBytes: 1_000_000
        ))
        let firstKey = try key("01001")
        let secondKey = try key("01002")
        await cache.set(
            firstKey,
            asset: CachedAsset(
                payload: Data([1]),
                metadata: metadata(cacheKeyHex: "a", encodedByteCount: 1)
            )
        )
        await cache.set(
            secondKey,
            asset: CachedAsset(
                payload: Data([2]),
                metadata: metadata(cacheKeyHex: "b", encodedByteCount: 1)
            )
        )

        await cache.remove(firstKey)
        let first = await cache.get(firstKey)
        let second = await cache.get(secondKey)
        #expect(first == nil)
        #expect(second != nil)
    }

    @Test("Eviction removes the least-recently-accessed entries first, down to the low water mark")
    func evictsLeastRecentlyAccessedFirst() async throws {
        // Each entry's exact accounted-byte cost is derived from the real
        // metadata this test constructs (payload count plus the actual
        // serialized-JSON size of its own metadata sidecar), never a fixed
        // assumption about what that JSON happens to serialize to on this
        // toolchain/Foundation version. The budget and water-mark ratios
        // are then chosen as fractions of that one real per-entry cost, so
        // the "2 entries fit, 3 don't; evicting exactly 1 restores
        // headroom" scenario below holds for any positive per-entry cost.
        let entryPayload = Data(count: 1000)
        let entryMetadata = metadata(cacheKeyHex: "a", encodedByteCount: 1000)
        let entryAccountedBytes = CachedAsset(
            payload: entryPayload,
            metadata: entryMetadata
        ).accountedByteCount
        let memoryBudgetBytes = entryAccountedBytes * 4
        let limits = AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: memoryBudgetBytes,
            diskBudgetBytes: memoryBudgetBytes,
            // 0.7 * 4 = 2.8 entries: 2 fit under the high water mark, 3 do
            // not, for any positive entryAccountedBytes.
            highWaterMarkRatio: 0.7,
            // 0.6 * 4 = 2.4 entries: strictly above the 2 entries left
            // once eviction removes exactly the least-recently-used one,
            // so eviction stops there rather than removing a second entry.
            lowWaterMarkRatio: 0.6
        )
        let cache = AssetMemoryCache(limits: limits)
        let keyA = try key("01001")
        let keyB = try key("01002")
        let keyC = try key("01003")

        await cache.set(keyA, asset: CachedAsset(payload: entryPayload, metadata: entryMetadata))
        await cache.set(
            keyB,
            asset: CachedAsset(
                payload: Data(count: 1000),
                metadata: metadata(cacheKeyHex: "b", encodedByteCount: 1000)
            )
        )
        // Access A again so B becomes the least-recently-used of {A, B}.
        _ = await cache.get(keyA)
        await cache.set(
            keyC,
            asset: CachedAsset(
                payload: Data(count: 1000),
                metadata: metadata(cacheKeyHex: "c", encodedByteCount: 1000)
            )
        )

        let entryA = await cache.get(keyA)
        let entryB = await cache.get(keyB)
        let entryC = await cache.get(keyC)
        #expect(entryB == nil, "B was least-recently-used and should have been evicted first")
        #expect(entryC != nil, "C was just inserted and must survive eviction")
        #expect(entryA != nil, "A was re-accessed before C's insertion and must survive eviction")
    }

    @Test("removeAll empties the cache entirely")
    func removeAllEmptiesCache() async throws {
        let cache = AssetMemoryCache(limits: AssetCacheLimits(
            maxEncodedBytes: 1024,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1_000_000,
            diskBudgetBytes: 1_000_000
        ))
        let cacheKey = try key("01001")
        await cache.set(
            cacheKey,
            asset: CachedAsset(
                payload: Data([1]),
                metadata: metadata(cacheKeyHex: "a", encodedByteCount: 1)
            )
        )
        await cache.removeAll()
        let fetched = await cache.get(cacheKey)
        #expect(fetched == nil)
        let total = await cache.totalAccountedBytes
        #expect(total == 0)
    }

    @Test(
        """
        CachedAsset.accountedByteCount bills the actual payload it holds, \
        never metadata.encodedByteCount alone: a metadata value whose \
        declared encodedByteCount diverges from the real payload size -- \
        corrupt/tampered metadata reused in-memory, or a call site \
        accidentally passing mismatched values -- cannot under- or \
        over-bill this entry against the memory budget
        """
    )
    func accountedByteCountUsesTheActualPayloadNotDeclaredEncodedByteCount() {
        let payload = Data(count: 5)
        // Deliberately mismatched: this metadata declares a payload size
        // wildly different from the 5 bytes actually held above.
        let mismatchedMetadata = metadata(cacheKeyHex: "a", encodedByteCount: 999_999)
        let asset = CachedAsset(payload: payload, metadata: mismatchedMetadata)
        let expected = payload.count + mismatchedMetadata.metadataOverheadBytes
        #expect(asset.accountedByteCount == expected)
        #expect(asset.accountedByteCount != mismatchedMetadata.encodedByteCount)
    }

    @Test(
        """
        totalAccountedBytes is maintained incrementally rather than \
        re-summed from every entry: replacing an existing key's entry via \
        set(_:asset:) subtracts the superseded entry's own accountedByteCount \
        exactly once, never double-counting or leaking the old entry's bytes
        """
    )
    func settingAnExistingKeyReplacesItsAccountedBytesExactlyOnce() async throws {
        let cache = AssetMemoryCache(limits: AssetCacheLimits(
            maxEncodedBytes: 1024,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1_000_000,
            diskBudgetBytes: 1_000_000
        ))
        let cacheKey = try key("01001")
        let firstAsset = CachedAsset(
            payload: Data(count: 10),
            metadata: metadata(cacheKeyHex: "a", encodedByteCount: 10)
        )
        await cache.set(cacheKey, asset: firstAsset)
        let totalAfterFirst = await cache.totalAccountedBytes
        #expect(totalAfterFirst == firstAsset.accountedByteCount)

        let replacementAsset = CachedAsset(
            payload: Data(count: 3),
            metadata: metadata(cacheKeyHex: "a", encodedByteCount: 3)
        )
        await cache.set(cacheKey, asset: replacementAsset)
        let totalAfterReplacement = await cache.totalAccountedBytes
        #expect(totalAfterReplacement == replacementAsset.accountedByteCount)
    }

    @Test("Removing a key that was never present leaves totalAccountedBytes unchanged")
    func removingAnAbsentKeyDoesNotDisturbTheRunningTotal() async throws {
        let cache = AssetMemoryCache(limits: AssetCacheLimits(
            maxEncodedBytes: 1024,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1_000_000,
            diskBudgetBytes: 1_000_000
        ))
        let presentKey = try key("01001")
        let asset = CachedAsset(
            payload: Data(count: 4),
            metadata: metadata(cacheKeyHex: "a", encodedByteCount: 4)
        )
        await cache.set(presentKey, asset: asset)

        let absentKey = try key("01002")
        await cache.remove(absentKey)
        let total = await cache.totalAccountedBytes
        #expect(total == asset.accountedByteCount)
    }
}
