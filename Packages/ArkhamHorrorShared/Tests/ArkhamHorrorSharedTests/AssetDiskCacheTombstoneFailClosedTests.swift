@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves ``AssetDiskCache/get(_:)``'s fail-closed checks —
/// ``AssetDiskCache/isTombstoned(keyHash:)`` and
/// ``AssetDiskCache/areDiskReadsDisabled()`` — actually fail *closed* when
/// the underlying ``SecureCacheDirectory/attributes(name:)`` call cannot
/// even determine whether the marker exists (a genuine `fstatat` failure:
/// permission, I/O, etc — as opposed to "the marker is simply absent",
/// which `attributes(name:)` reports as `nil`, not a thrown error).
///
/// Before the fix under test, both checks collapsed a thrown
/// `attributes(name:)` failure into "no marker present" via `try?`,
/// silently failing *open*: exactly the outcome these two safety markers
/// exist to prevent (a durable tombstone/whole-cache-disabled marker whose
/// entire purpose is to keep an otherwise-structurally-valid-looking entry
/// from ever being served again).
@Suite("AssetDiskCache tombstone/disabled-marker fail-closed checks")
struct AssetDiskCacheTombstoneFailClosedTests {
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
        A genuine (non-ENOENT) attributes() failure while checking a key's tombstone \
        marker is treated as tombstoned (fail closed), never as "no tombstone"
        """
    )
    func tombstoneCheckFailureFailsClosed() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )
            // A genuinely valid, structurally-clean entry: without any
            // fault injection this would be served normally.
            #expect(try await cache.get(cacheKey) != nil)

            await cache.directoryAccess.installFaultInjection(
                failAttributesSuffixes: [".tombstone"]
            )
            #expect(try await cache.get(cacheKey) == nil)
        }
    }

    @Test(
        """
        A genuine (non-ENOENT) attributes() failure while checking the whole-cache \
        disabled marker is treated as disabled (fail closed), never as "reads enabled"
        """
    )
    func diskReadsDisabledCheckFailureFailsClosed() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )
            #expect(try await cache.get(cacheKey) != nil)

            await cache.directoryAccess.installFaultInjection(
                failAttributesSuffixes: [AssetDiskCache.diskReadsDisabledMarkerName]
            )
            #expect(try await cache.get(cacheKey) == nil)
        }
    }
}
