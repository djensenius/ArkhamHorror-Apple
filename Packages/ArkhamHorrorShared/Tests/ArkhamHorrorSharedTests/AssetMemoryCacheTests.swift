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
        // Budget of 4000 bytes, high water 95% = 3800, low water 76% = 3040.
        // Each entry accounts for 1000 + 512 = 1512 bytes. Budget/ratios are
        // chosen so that two entries fit under the high water mark (no
        // premature eviction), but a third entry pushes total usage over
        // it, triggering eviction of exactly the least-recently-used entry
        // down to (at or below) the low water mark.
        let limits = AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 4000,
            diskBudgetBytes: 4000,
            highWaterMarkRatio: 0.95, // 3800: 2 entries (3024) fit; 3 (4536) don't.
            lowWaterMarkRatio: 0.76 // 3040: stops after evicting exactly one entry (leaves 3024).
        )
        let cache = AssetMemoryCache(limits: limits)
        let keyA = try key("01001")
        let keyB = try key("01002")
        let keyC = try key("01003")

        await cache.set(
            keyA,
            asset: CachedAsset(
                payload: Data(count: 1000),
                metadata: metadata(cacheKeyHex: "a", encodedByteCount: 1000)
            )
        )
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
}
