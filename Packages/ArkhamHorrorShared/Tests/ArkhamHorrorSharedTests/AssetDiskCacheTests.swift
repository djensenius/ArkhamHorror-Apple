@testable import ArkhamHorrorShared
import Foundation
import Testing

@Suite("AssetDiskCache")
struct AssetDiskCacheTests {
    /// A fresh scratch directory per test, nested under this package's own
    /// build output (never `/tmp`), removed unconditionally when the test
    /// finishes.
    func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("DiskCacheScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    func key(_ rawCardCode: String) throws -> AssetCacheKey {
        let identifier = try AssetIdentifier.cardCode(rawCardCode)
        let assetKey = AssetKey(category: .card(.art, identifier))
        let candidates = AssetLocator.candidates(for: assetKey, digest: FakeDigestLookup())
        return AssetCacheKey(for: assetKey, candidates: candidates)
    }

    func metadata(
        for cacheKey: AssetCacheKey,
        payload: Data,
        at date: Date = Date()
    ) -> AssetCacheMetadata {
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
            insertedAt: date,
            lastAccessedAt: date
        )
    }

    func smallLimits(diskBudgetBytes: Int = 1_000_000) -> AssetCacheLimits {
        AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1_000_000,
            diskBudgetBytes: diskBudgetBytes
        )
    }

    // MARK: - Round trip

    @Test("A stored entry can be read back with an identical payload and metadata")
    func setThenGetRoundTrips() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            let fetched = await cache.get(cacheKey)
            #expect(fetched?.payload == payload)
            #expect(fetched?.metadata.payloadSHA256Hex == AssetPayloadHasher.sha256Hex(payload))
        }
    }

    @Test("A missing key returns nil, without creating any file")
    func missingKeyReturnsNilAndCreatesNoFiles() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let fetched = await cache.get(cacheKey)
            #expect(fetched == nil)
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(contents.isEmpty)
        }
    }

    // MARK: - Corrupt entry quarantine

    @Test(
        "A payload whose bytes no longer match its recorded SHA-256 is quarantined as a miss"
    )
    func corruptPayloadHashMismatchQuarantined() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            // Tamper with the payload on disk directly, bypassing the cache API.
            let payloadURL = directory.appendingPathComponent("\(cacheKey.digestHex).bin")
            try Data([9, 9, 9]).write(to: payloadURL)

            let fetched = await cache.get(cacheKey)
            #expect(fetched == nil)
            #expect(
                !FileManager.default.fileExists(atPath: payloadURL.path),
                "A corrupt entry must be removed, not left behind"
            )
        }
    }

    @Test("Metadata whose recorded schema version does not match the current schema is quarantined")
    func schemaVersionMismatchQuarantined() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            // Overwrite the metadata sidecar with a future/unknown schema
            // version by round-tripping through raw JSON.
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            var json = try #require(
                try JSONSerialization
                    .jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
            )
            json["schemaVersion"] = 999
            let tampered = try JSONSerialization.data(withJSONObject: json)
            try tampered.write(to: metadataURL)

            let fetched = await cache.get(cacheKey)
            #expect(fetched == nil)
        }
    }

    @Test("Undecodable (garbage) metadata is quarantined rather than thrown as an error")
    func undecodableMetadataQuarantined() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payloadURL = directory.appendingPathComponent("\(cacheKey.digestHex).bin")
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            try Data([1, 2, 3]).write(to: payloadURL)
            try Data("not json".utf8).write(to: metadataURL)

            let fetched = await cache.get(cacheKey)
            #expect(fetched == nil)
            #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
        }
    }

    // MARK: - Orphan / temp-file recovery

    @Test("An orphaned payload file with no metadata sidecar is removed on first access")
    func orphanedPayloadWithoutMetadataRemoved() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payloadURL = directory.appendingPathComponent("\(cacheKey.digestHex).bin")
            try Data([1, 2, 3]).write(to: payloadURL)

            // Any access triggers the once-per-instance orphan sweep.
            _ = try await cache.get(key("01002"))
            #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
        }
    }

    @Test("An orphaned metadata sidecar with no payload file is removed on first access")
    func orphanedMetadataWithoutPayloadRemoved() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            let payload = Data([1, 2, 3])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata(for: cacheKey, payload: payload)).write(to: metadataURL)

            _ = try await cache.get(key("01002"))
            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
        }
    }

    @Test("A leftover .tmp file from an interrupted write is removed on first access")
    func leftoverTempFileRemoved() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let tempURL = directory.appendingPathComponent("deadbeef.bin.tmp")
            try Data([1, 2, 3]).write(to: tempURL)

            _ = try await cache.get(key("01001"))
            #expect(!FileManager.default.fileExists(atPath: tempURL.path))
        }
    }
}
