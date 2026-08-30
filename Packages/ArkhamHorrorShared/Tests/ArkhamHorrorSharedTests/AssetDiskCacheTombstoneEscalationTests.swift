@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves ``AssetDiskCache/Removal/remove(_:token:)`` escalates to the
/// whole-cache ``AssetDiskCache/markDiskReadsDisabled()`` fail-closed
/// marker when *both* its own metadata-pointer deletion *and* its
/// fallback per-key ``AssetDiskCache/persistTombstoneLocked(keyHash:)``
/// write fail — the compounding failure this cumulative review's item 5
/// specifically calls out: a failed deletion whose per-key tombstone
/// write also fails leaves that key with no durable protection at all,
/// so without this escalation a fresh process (or a fresh
/// ``AssetDiskCache`` instance, simulating one) could serve the
/// supposedly invalidated entry again.
@Suite("AssetDiskCache double-failure tombstone escalation")
struct AssetDiskCacheTombstoneEscalationTests {
    private func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("DiskCacheScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private func key(_ rawCardCode: String) throws -> AssetCacheKey {
        let identifier = try AssetIdentifier.cardCode(rawCardCode)
        let assetKey = AssetKey(category: .card(.art, identifier))
        let candidates = AssetLocator.candidates(for: assetKey, digest: FakeDigestLookup())
        return AssetCacheKey(for: assetKey, candidates: candidates)
    }

    private func metadata(for cacheKey: AssetCacheKey, payload: Data) -> AssetCacheMetadata {
        AssetCacheMetadata(
            cacheKeyHex: cacheKey.digestHex,
            contentType: "image/png",
            encodedByteCount: payload.count,
            width: 4,
            height: 4,
            payloadSHA256Hex: AssetPayloadHasher.sha256Hex(payload),
            etag: nil,
            lastModified: nil,
            resolvedURLString: "https://example.com/\(cacheKey.digestHex)",
            insertedAt: Date(),
            accessSequence: AssetAccessSequence(0)
        )
    }

    private func limits() -> AssetCacheLimits {
        AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1_000_000,
            diskBudgetBytes: 1_000_000
        )
    }

    @Test(
        """
        When both the metadata-pointer removal and the per-key tombstone write fail, \
        remove(_:token:) escalates to the whole-cache disk-reads-disabled marker, and a \
        brand-new AssetDiskCache instance over the same directory (simulating a restart) \
        still refuses to serve the key -- and every other key -- until a full removeAll()
        """
    )
    func bothFailuresEscalateToWholeCacheDisabledMarker() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key("01001")
            let otherKey = try key("01002")
            let payload = Data([1, 2, 3, 4, 5])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )
            try await cache.set(
                otherKey,
                payload: payload,
                metadata: metadata(for: otherKey, payload: payload)
            )
            #expect(try await cache.get(cacheKey) != nil)
            #expect(try await cache.get(otherKey) != nil)

            // Fail both the metadata-pointer's own removal *and* the
            // fallback tombstone write for this exact key, in one shot:
            // `failRemoveSuffixes` targets the `.meta.json` removal
            // itself, `failSuffixes` targets the `.tombstone` temp-file
            // write `persistTombstoneLocked` performs.
            await cache.directoryAccess.installFaultInjection(
                failSuffixes: [".tombstone"],
                failRemoveSuffixes: [".meta.json"]
            )

            await #expect(throws: (any Error).self) {
                try await cache.remove(cacheKey)
            }

            // Clear the fault injection before probing further -- the
            // escalation itself, not the injected fault, is what must
            // now be keeping every key unservable.
            await cache.directoryAccess.installFaultInjection()

            // The whole-cache marker refuses *every* key, not just the
            // one whose deletion failed -- including a key that was
            // never touched by this failure at all.
            #expect(try await cache.get(cacheKey) == nil)
            #expect(try await cache.get(otherKey) == nil)

            // A brand-new instance over the same directory (standing in
            // for a process restart) must still see the durable marker
            // on disk and refuse to serve anything.
            let restarted = try AssetDiskCache(directory: directory, limits: limits())
            #expect(try await restarted.get(cacheKey) == nil)
            #expect(try await restarted.get(otherKey) == nil)

            // Only a fully successful removeAll() is treated as the
            // durable "clear/replacement" event that lifts the marker.
            try await restarted.removeAll()
            // The entries themselves are now actually gone (removeAll
            // swept everything), so this only proves reads are no
            // longer unconditionally refused -- not that the old
            // (already-removed) entries reappear.
            let freshKey = try key("01003")
            let freshPayload = Data([9, 9, 9])
            try await restarted.set(
                freshKey,
                payload: freshPayload,
                metadata: metadata(for: freshKey, payload: freshPayload)
            )
            #expect(try await restarted.get(freshKey)?.payload == freshPayload)
        }
    }
}
