@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Disk-persistence failure auditability for ``AssetCacheService/publish``,
/// and restart-time re-validation of persisted disk hits (finding #8).
/// Split out from `AssetCacheServiceTests.swift` (reusing its
/// `withScratchDirectory`/`cardArtKey`/`candidateURLs`/`successResult`
/// helpers, and `AssetDiskCacheTests.swift`'s `FailingFileManager`) purely
/// to stay under SwiftLint's `type_body_length`.
///
/// The two `FailingFileManager`-based tests below construct
/// ``AssetDiskCache`` directly inline (rather than through the
/// `makeService` helpers further down) so the injected
/// `FailingFileManager` — a `@unchecked Sendable`-conforming subclass of
/// the otherwise non-`Sendable` `FileManager` — is passed to
/// `AssetDiskCache.init` at its own concrete type in a direct, same-region
/// call. Routing it through any intervening function or closure parameter
/// defeats the compiler's region-based "sending to an actor-isolated
/// initializer" analysis, even though the direct call site itself is
/// provably safe (the value has no other live references).
extension AssetCacheServiceTests {
    /// Every layer of a single ``AssetCacheService`` wiring: grouped into
    /// one value (rather than a bare tuple) purely so `makeService`'s
    /// return stays under SwiftLint's `large_tuple` limit.
    struct ServiceLayers {
        let memoryCache: AssetMemoryCache
        let diskCache: AssetDiskCache
        let transport: FakeAssetTransport
        let service: AssetCacheService
    }

    /// The common limits shared by nearly every test in this file, with
    /// only `maxPixelCount` ever varying between them.
    func standardLimits(maxPixelCount: Int = 32_000_000) -> AssetCacheLimits {
        AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: maxPixelCount,
            memoryBudgetBytes: 10_000_000,
            diskBudgetBytes: 10_000_000
        )
    }

    /// Builds a fresh memory cache, disk cache, fake transport, and
    /// service wired together over `directory`, reducing every test below
    /// to stating only what actually varies between them.
    func makeService(directory: URL, limits: AssetCacheLimits) throws -> ServiceLayers {
        let diskCache = try AssetDiskCache(directory: directory, limits: limits)
        return makeService(diskCache: diskCache, limits: limits)
    }

    /// Same as above, but reusing an already-constructed disk cache — for
    /// tests that seed a disk entry directly (bypassing
    /// `AssetCacheService.publish`) before wiring up the service that will
    /// read it back.
    func makeService(diskCache: AssetDiskCache, limits: AssetCacheLimits) -> ServiceLayers {
        let memoryCache = AssetMemoryCache(limits: limits)
        let transport = FakeAssetTransport()
        let service = AssetCacheService(
            memoryCache: memoryCache,
            diskCache: diskCache,
            transport: transport,
            digest: FakeDigestLookup(),
            limits: limits
        )
        return ServiceLayers(
            memoryCache: memoryCache,
            diskCache: diskCache,
            transport: transport,
            service: service
        )
    }

    /// Directly seeds `diskCache` with `payload` under `key`'s own current
    /// cache key and candidate-resolved URL, claiming `metadataDimensions`
    /// in its metadata regardless of `payload`'s actual dimensions —
    /// simulating a self-consistent (valid hash/byte-count) but stale or
    /// tampered on-disk entry that only a full re-validation-on-read
    /// (finding #8) can catch.
    func seedDiskEntry(
        _ diskCache: AssetDiskCache,
        key: AssetKey,
        payload: Data,
        contentType: String,
        metadataDimensions: (width: Int, height: Int)
    ) async throws -> (cacheKey: AssetCacheKey, candidates: [AssetCandidate]) {
        let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)
        try await diskCache.set(
            cacheKey,
            payload: payload,
            metadata: AssetCacheMetadata(
                cacheKeyHex: cacheKey.digestHex,
                contentType: contentType,
                encodedByteCount: payload.count,
                width: metadataDimensions.width,
                height: metadataDimensions.height,
                payloadSHA256Hex: AssetPayloadHasher.sha256Hex(payload),
                etag: nil,
                lastModified: nil,
                resolvedURLString: candidates[0].url(base: key.source).absoluteString,
                insertedAt: Date(),
                lastAccessedAt: Date()
            )
        )
        return (cacheKey, candidates)
    }

    /// Enqueues a successful, genuinely-decodable PNG HTTP response for
    /// `url`, the fresh-fetch fallback every restart/quarantine test below
    /// expects once its seeded stale entry is rejected.
    func enqueuePNGResponse(
        _ transport: FakeAssetTransport,
        url: URL,
        width: Int,
        height: Int
    ) async {
        await transport.enqueue(
            .success(.success(AssetHTTPResponse(
                body: AssetImageFixtureBuilder.validPNG(width: width, height: height),
                contentType: "image/png",
                etag: nil,
                lastModified: nil
            ))),
            for: url
        )
    }

    @Test(
        """
        A disk-cache persistence failure during publish is captured for auditing, \
        but the resolved asset is still returned (in-memory cache remains usable)
        """
    )
    func diskPersistenceFailureIsAuditedNotFatal() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let failingFileManager = FailingFileManager()
            failingFileManager.failPathSuffixes = [".bin"]
            let diskCache = try AssetDiskCache(
                directory: directory,
                limits: limits,
                fileManager: failingFileManager
            )
            let layers = makeService(diskCache: diskCache, limits: limits)

            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await layers.transport.enqueue(.success(successResult()), for: urls[0])

            // The disk write fails (payload move injected to fail), but
            // resolution itself must still succeed since the asset is
            // already validated and stored in the in-memory cache.
            let asset = try await layers.service.asset(for: key)
            #expect(asset.payload == AssetImageFixtureBuilder.validAVIF(width: 4, height: 4))

            let failure = await layers.service.lastDiskPersistenceFailure
            #expect(
                failure != nil,
                "A failed disk write must be captured for auditing, not silently swallowed"
            )
        }
    }

    @Test("A successful publish clears any previously recorded disk-persistence failure")
    func successfulPublishClearsPriorFailure() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let firstKey = try cardArtKey("01001")
            let firstCandidates = AssetLocator.candidates(
                for: firstKey,
                digest: FakeDigestLookup()
            )
            let firstCacheKey = AssetCacheKey(for: firstKey, candidates: firstCandidates)

            let failingFileManager = FailingFileManager()
            failingFileManager.failPathPrefixes = ["\(firstCacheKey.digestHex)."]
            let diskCache = try AssetDiskCache(
                directory: directory,
                limits: limits,
                fileManager: failingFileManager
            )
            let layers = makeService(diskCache: diskCache, limits: limits)

            let firstURLs = candidateURLs(for: firstKey)
            await layers.transport.enqueue(.success(successResult()), for: firstURLs[0])
            _ = try await layers.service.asset(for: firstKey)
            let firstFailure = await layers.service.lastDiskPersistenceFailure
            #expect(firstFailure != nil)

            // A different key's payload/metadata filenames do not match
            // the injected failure prefix, so this publish succeeds and
            // must clear the previously recorded failure.
            let secondKey = try cardArtKey("01002")
            let secondURLs = candidateURLs(for: secondKey)
            await layers.transport.enqueue(.success(successResult()), for: secondURLs[0])
            _ = try await layers.service.asset(for: secondKey)
            let secondFailure = await layers.service.lastDiskPersistenceFailure
            #expect(secondFailure == nil)
        }
    }

    // MARK: - Finding #8: persisted disk hits are re-validated, never trusted as-is

    @Test(
        """
        A disk entry cached under looser limits is quarantined and refetched, rather than \
        served as-is, once a subsequent process restarts with a stricter pixel-count limit
        """
    )
    func restartUnderStricterLimitsQuarantinesOversizedEntry() async throws {
        try await withScratchDirectory { directory in
            let key = try setIconKey()

            // First "process": publish a 100x100 PNG (10,000px) under
            // loose limits.
            do {
                let layers = try makeService(directory: directory, limits: standardLimits())
                let urls = candidateURLs(for: key)
                await enqueuePNGResponse(layers.transport, url: urls[0], width: 100, height: 100)
                _ = try await layers.service.asset(for: key)
            }

            // Second "process": a stricter maxPixelCount (5,000) that the
            // already-cached 100x100 (10,000px) entry now exceeds.
            let layers = try makeService(
                directory: directory,
                limits: standardLimits(maxPixelCount: 5000)
            )
            let urls = candidateURLs(for: key)
            await enqueuePNGResponse(layers.transport, url: urls[0], width: 4, height: 4)

            let asset = try await layers.service.asset(for: key)
            #expect(
                asset.payload == AssetImageFixtureBuilder.validPNG(width: 4, height: 4),
                """
                The oversized stale entry must be quarantined and a fresh, in-limits fetch \
                performed instead of being served as-is
                """
            )
            let callCount = await layers.transport.callCount(for: urls[0])
            #expect(callCount == 1)
        }
    }

    @Test(
        """
        A disk entry whose metadata claims a format that does not match its own current \
        candidate's expected format is quarantined and refetched rather than served
        """
    )
    func wrongFormatSelfConsistentEntryQuarantined() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            // `setIconKey` expects PNG; inject a genuinely-decodable JPEG
            // under its cache key directly (bypassing
            // `AssetCacheService.publish`, which would never allow this
            // mismatch to occur), simulating either a corrupted cache
            // directory or a stale entry from before a format change.
            let key = try setIconKey()
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let wrongFormatPayload = AssetImageFixtureBuilder.validJPEG(width: 4, height: 4)
            _ = try await seedDiskEntry(
                diskCache,
                key: key,
                payload: wrongFormatPayload,
                contentType: "image/jpeg",
                metadataDimensions: (width: 4, height: 4)
            )

            let layers = makeService(diskCache: diskCache, limits: limits)
            let urls = candidateURLs(for: key)
            await enqueuePNGResponse(layers.transport, url: urls[0], width: 4, height: 4)

            let asset = try await layers.service.asset(for: key)
            #expect(asset.payload == AssetImageFixtureBuilder.validPNG(width: 4, height: 4))
        }
    }

    @Test(
        """
        A disk entry whose metadata dimensions match its own hash-verified bytes, but whose \
        real parsed dimensions were tampered to differ from those bytes' actual content, is \
        quarantined and refetched rather than trusted on metadata alone
        """
    )
    func selfConsistentEntryWithTamperedDimensionsQuarantined() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let key = try setIconKey()
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            // The payload is a genuine, hash-verifiable 200x200 PNG, but
            // the metadata claims 4x4 — internally self-consistent by the
            // hash/byte-count checks `AssetDiskCache.get` already
            // performs, but not by an actual re-parse of the bytes.
            let payload = AssetImageFixtureBuilder.validPNG(width: 200, height: 200)
            _ = try await seedDiskEntry(
                diskCache,
                key: key,
                payload: payload,
                contentType: "image/png",
                metadataDimensions: (width: 4, height: 4)
            )

            let layers = makeService(diskCache: diskCache, limits: limits)
            let urls = candidateURLs(for: key)
            await enqueuePNGResponse(layers.transport, url: urls[0], width: 4, height: 4)

            let asset = try await layers.service.asset(for: key)
            #expect(asset.payload == AssetImageFixtureBuilder.validPNG(width: 4, height: 4))
        }
    }

    @Test(
        "A disk entry with corrupt (non-decodable JSON) metadata is treated as a cache miss"
    )
    func corruptMetadataTreatedAsCacheMiss() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let key = try setIconKey()
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let payload = AssetImageFixtureBuilder.validPNG(width: 4, height: 4)
            let (cacheKey, _) = try await seedDiskEntry(
                diskCache,
                key: key,
                payload: payload,
                contentType: "image/png",
                metadataDimensions: (width: 4, height: 4)
            )
            // Corrupt the metadata sidecar file directly on disk with
            // non-JSON bytes, after a valid entry was published through
            // the normal path.
            let metadataURL = directory
                .appendingPathComponent("\(cacheKey.digestHex).meta.json")
            try Data("not valid json".utf8).write(to: metadataURL)

            let layers = makeService(diskCache: diskCache, limits: limits)
            let urls = candidateURLs(for: key)
            await enqueuePNGResponse(layers.transport, url: urls[0], width: 4, height: 4)

            let asset = try await layers.service.asset(for: key)
            #expect(asset.payload == AssetImageFixtureBuilder.validPNG(width: 4, height: 4))
        }
    }
}
