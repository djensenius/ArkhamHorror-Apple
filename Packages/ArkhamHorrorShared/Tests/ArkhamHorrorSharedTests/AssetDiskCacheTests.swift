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
            accessSequence: AssetAccessSequence(0)
        )
    }

    /// The exact on-disk filename ``AssetDiskCache`` derives for `payload`
    /// under `cacheKey`: content-addressed by `payload`'s own SHA-256, not
    /// a fixed name — a stored entry's payload filename changes if its
    /// bytes ever do (a replacement never overwrites a prior generation's
    /// file in place). Centralized here so every test that pokes at the
    /// payload file directly derives the same filename the production
    /// code does, rather than each hard-coding the old fixed-name scheme.
    func payloadFileURL(directory: URL, cacheKey: AssetCacheKey, payload: Data) -> URL {
        directory.appendingPathComponent(
            "\(cacheKey.digestHex).\(AssetPayloadHasher.sha256Hex(payload)).bin"
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

    @Test(
        """
        set(_:payload:metadata:) always (re)writes the content-addressed payload \
        file, even when a file with the exact same content-hash name already \
        exists on disk: a matching filename alone is not proof the existing bytes \
        are still intact, so a pre-existing (possibly corrupted/tampered) file at \
        that path must never be trusted and left as-is — it is always overwritten \
        with the caller's known-good bytes
        """
    )
    func setOverwritesAPreExistingFileAtTheSameContentAddressedNameRatherThanTrustingIt(
    ) async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: payload
            )

            // Simulate a payload file that already exists at the exact name
            // `set` is about to publish under, but whose bytes are corrupted
            // (e.g. a prior crash, or on-disk tampering) rather than the
            // genuine payload — this must never happen for a correctly
            // computed content hash, but the write path must not assume that.
            try Data([9, 9, 9]).write(to: payloadURL)

            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload)
            )

            #expect(try Data(contentsOf: payloadURL) == payload)
            let fetched = await cache.get(cacheKey)
            #expect(fetched?.payload == payload)
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
            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: payload
            )
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
            let payload = Data([1, 2, 3])
            let payloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: payload
            )
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            try payload.write(to: payloadURL)
            try Data("not json".utf8).write(to: metadataURL)

            let fetched = await cache.get(cacheKey)
            #expect(fetched == nil)
            #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
        }
    }

    @Test(
        """
        Quarantining undecodable metadata on `get` sweeps every stale payload generation for \
        that key hash, not only whichever one file happens to be corrupt, even when the \
        one-time startup orphan sweep has already run and so cannot reclaim them later
        """
    )
    func quarantiningCorruptMetadataOnGetSweepsOtherStaleGenerationsForSameKeyHash() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")

            // Force `recoverOrphansIfNeeded()`'s one-time startup sweep to
            // have already run via an unrelated miss, before any of this
            // test's own stray files exist. This proves the fix does not
            // merely rely on that one-time sweep to reclaim what it
            // creates below.
            _ = try await cache.get(key("01002"))

            let currentPayload = Data([1, 2, 3])
            let currentPayloadURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: currentPayload
            )
            try currentPayload.write(to: currentPayloadURL)

            // A stray extra generation for the *same* key hash, as a crash
            // between an earlier payload write and its metadata commit
            // might leave behind. Nothing references it.
            let staleSiblingPayload = Data([9, 9, 9, 9])
            let staleSiblingURL = payloadFileURL(
                directory: directory,
                cacheKey: cacheKey,
                payload: staleSiblingPayload
            )
            try staleSiblingPayload.write(to: staleSiblingURL)

            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            try Data("not json".utf8).write(to: metadataURL)

            let fetched = await cache.get(cacheKey)
            #expect(fetched == nil)
            #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
            #expect(
                !FileManager.default.fileExists(atPath: currentPayloadURL.path),
                "The generation the corrupt metadata referenced must be removed"
            )
            #expect(
                !FileManager.default.fileExists(atPath: staleSiblingURL.path),
                """
                An unrelated stale generation for the same key hash must also be swept, not \
                left to wait for a future process restart's orphan sweep
                """
            )
        }
    }
}
