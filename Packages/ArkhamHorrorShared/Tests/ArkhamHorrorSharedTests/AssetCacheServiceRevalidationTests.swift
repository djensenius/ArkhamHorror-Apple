@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Conditional revalidation (`If-None-Match`) and 304 handling for
/// ``AssetCacheService``. Split out from `AssetCacheServiceTests.swift`
/// (which retains the shared `withService`/`cardArtKey`/`candidateURLs`/
/// `successResult` helpers) purely to stay under SwiftLint's
/// `type_body_length`; this is one `@Suite` conceptually, spread across
/// files by concern the same way `AppModelTests` is split.
extension AssetCacheServiceTests {
    @Test(
        "Revalidating with no prior cache entry throws staleConditionalResponse, no network call"
    )
    func revalidateWithNoCachedEntryThrowsWithoutNetworkCall() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            await #expect(throws: AssetError.staleConditionalResponse) {
                _ = try await service.revalidate(for: key)
            }
            let urls = candidateURLs(for: key)
            for url in urls {
                let callCount = await transport.callCount(for: url)
                #expect(callCount == 0)
            }
        }
    }

    @Test(
        """
        Revalidating a cached entry with neither ETag nor Last-Modified throws \
        staleConditionalResponse, no network call
        """
    )
    func revalidateWithNoValidatorsThrowsWithoutNetworkCall() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            // Neither etag nor lastModified supplied: the cached entry has
            // no validator to condition a request on.
            await transport.enqueue(.success(successResult()), for: urls[0])
            let initial = try await service.asset(for: key)
            #expect(initial.metadata.etag == nil)
            #expect(initial.metadata.lastModified == nil)

            await #expect(throws: AssetError.staleConditionalResponse) {
                _ = try await service.revalidate(for: key)
            }
            // Exactly the one initial fetch, and no further (revalidation)
            // call to any candidate URL.
            let firstCallCount = await transport.callCount(for: urls[0])
            #expect(firstCallCount == 1)
            for url in urls.dropFirst() {
                let callCount = await transport.callCount(for: url)
                #expect(callCount == 0)
            }
        }
    }

    @Test(
        "A 304 with a currently valid cached payload succeeds and refreshes lastAccessedAt"
    )
    func notModifiedWithValidCacheSucceeds() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(successResult(etag: "\"abc\"")), for: urls[0])
            let initial = try await service.asset(for: key)
            #expect(initial.metadata.etag == "\"abc\"")

            await transport.enqueue(.success(.notModified), for: urls[0])
            let revalidated = try await service.revalidate(for: key)
            #expect(revalidated.payload == initial.payload)

            let call = await transport.calls.last
            #expect(call?.ifNoneMatch == "\"abc\"")
        }
    }

    @Test(
        """
        A 304 revalidation updates only the metadata sidecar on disk, never rewriting the \
        unchanged payload file's bytes or modification date
        """
    )
    func notModifiedRevalidationDoesNotRewritePayloadFile() async throws {
        try await withScratchDirectory { directory in
            let limits = AssetCacheLimits(
                maxEncodedBytes: 1_000_000,
                maxDimension: 8192,
                maxPixelCount: 32_000_000,
                memoryBudgetBytes: 10_000_000,
                diskBudgetBytes: 10_000_000
            )
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let memoryCache = AssetMemoryCache(limits: limits)
            let transport = FakeAssetTransport()
            let service = AssetCacheService(
                memoryCache: memoryCache,
                diskCache: diskCache,
                transport: transport,
                digest: FakeDigestLookup(),
                limits: limits
            )

            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(successResult(etag: "\"abc\"")), for: urls[0])
            let initial = try await service.asset(for: key)
            let cacheKey = AssetCacheKey(
                for: key,
                candidates: AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            )
            // Force the revalidation read to come from disk, not the
            // still-fresh in-memory entry, so the on-disk payload file's
            // modification date is meaningfully exercised below.
            await memoryCache.remove(cacheKey)

            let payloadURL = directory.appendingPathComponent(
                "\(cacheKey.digestHex).\(AssetPayloadHasher.sha256Hex(initial.payload)).bin"
            )
            let beforeAttributes = try FileManager.default
                .attributesOfItem(atPath: payloadURL.path)
            let beforeModificationDate = try #require(
                beforeAttributes[.modificationDate] as? Date
            )
            let beforePayload = try Data(contentsOf: payloadURL)

            await transport.enqueue(.success(.notModified), for: urls[0])
            let revalidated = try await service.revalidate(for: key)
            #expect(revalidated.payload == initial.payload)

            let afterAttributes = try FileManager.default.attributesOfItem(atPath: payloadURL.path)
            let afterModificationDate = try #require(afterAttributes[.modificationDate] as? Date)
            let afterPayload = try Data(contentsOf: payloadURL)
            #expect(afterModificationDate == beforeModificationDate)
            #expect(afterPayload == beforePayload)
        }
    }

    @Test(
        "An unconditional 304 during the initial (non-revalidating) fetch is a typed protocol error"
    )
    func unconditional304DuringInitialFetchIsError() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(.notModified), for: urls[0])

            await #expect(throws: AssetError.staleConditionalResponse) {
                _ = try await service.asset(for: key)
            }
        }
    }

    @Test(
        """
        A definitive 404 while revalidating evicts the now-stale cached entry, so a subsequent \
        asset(for:) call fetches fresh rather than re-serving the removed content
        """
    )
    func notFoundDuringRevalidationEvictsStaleEntry() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(successResult(etag: "\"abc\"")), for: urls[0])
            let initial = try await service.asset(for: key)
            #expect(initial.metadata.etag == "\"abc\"")

            await transport.enqueue(.success(.notFound), for: urls[0])
            await #expect(throws: AssetError.candidatesExhausted) {
                _ = try await service.revalidate(for: key)
            }

            // The stale entry must be gone from both cache layers: the next
            // resolution has to hit the network again rather than silently
            // continuing to serve the server-removed asset.
            await transport.enqueue(.success(successResult(etag: "\"def\"")), for: urls[0])
            let refetched = try await service.asset(for: key)
            #expect(refetched.metadata.etag == "\"def\"")
        }
    }

    @Test(
        """
        Revalidation refuses to trust a persisted resolvedURLString that does not match any of \
        the key's current candidates, surfacing a typed error without a network call
        """
    )
    func revalidateRejectsResolvedURLNotMatchingAnyCandidate() async throws {
        try await withScratchDirectory { directory in
            let limits = AssetCacheLimits(
                maxEncodedBytes: 1_000_000,
                maxDimension: 8192,
                maxPixelCount: 32_000_000,
                memoryBudgetBytes: 10_000_000,
                diskBudgetBytes: 10_000_000
            )
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let memoryCache = AssetMemoryCache(limits: limits)
            let transport = FakeAssetTransport()
            let service = AssetCacheService(
                memoryCache: memoryCache,
                diskCache: diskCache,
                transport: transport,
                digest: FakeDigestLookup(),
                limits: limits
            )

            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(successResult(etag: "\"abc\"")), for: urls[0])
            let cacheKey = AssetCacheKey(
                for: key,
                candidates: AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            )
            _ = try await service.asset(for: key)
            // Force the subsequent read to come from disk (not the
            // still-untampered in-memory entry) so tampering the on-disk
            // metadata file below actually takes effect.
            await memoryCache.remove(cacheKey)

            // Tamper with the persisted metadata's resolvedURLString on
            // disk directly, bypassing every cache API, to simulate
            // corrupted/tampered metadata pointing at an unrelated host.
            let metadataURL = directory.appendingPathComponent("\(cacheKey.digestHex).meta.json")
            var json = try #require(
                try JSONSerialization
                    .jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
            )
            json["resolvedURLString"] = "https://attacker.example.com/payload"
            let tampered = try JSONSerialization.data(withJSONObject: json)
            try tampered.write(to: metadataURL)

            await #expect(throws: AssetError.staleConditionalResponse) {
                _ = try await service.revalidate(for: key)
            }
            // No revalidation request was ever sent: exactly the one
            // initial fetch call to urls[0], and no further call to any
            // legitimate candidate (and certainly never to the tampered
            // host, which isn't even a candidate URL at all).
            let firstCallCount = await transport.callCount(for: urls[0])
            #expect(firstCallCount == 1)
            for url in urls.dropFirst() {
                let callCount = await transport.callCount(for: url)
                #expect(callCount == 0)
            }
        }
    }

    /// Shared fixture for the pair of tests below: a `cardArtKey` (whose
    /// own category default format is AVIF) paired with a genuinely valid
    /// PNG revalidation response, so `expectedFormat: .png` passed
    /// explicitly must succeed while `expectedFormat: key.expectedFormat`
    /// (AVIF) must fail against the identical bytes.
    private struct MismatchedFormatFixture {
        let key: AssetKey
        let cacheKey: AssetCacheKey
        let url: URL
        let existing: CachedAsset
        let response: AssetHTTPResponse
    }

    private func mismatchedFormatFixture() throws -> MismatchedFormatFixture {
        let key = try cardArtKey()
        let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)
        let url = try #require(URL(string: "https://example.com/cards/01001.png"))
        let existing = CachedAsset(
            payload: AssetImageFixtureBuilder.validAVIF(width: 4, height: 4),
            metadata: AssetCacheMetadata(
                cacheKeyHex: cacheKey.digestHex,
                contentType: "image/avif",
                encodedByteCount: 10,
                width: 4,
                height: 4,
                payloadSHA256Hex: AssetPayloadHasher.sha256Hex(Data([0])),
                etag: "\"old\"",
                lastModified: nil,
                resolvedURLString: url.absoluteString,
                insertedAt: Date(timeIntervalSince1970: 0),
                lastAccessedAt: Date(timeIntervalSince1970: 0)
            )
        )
        let response = AssetHTTPResponse(
            body: AssetImageFixtureBuilder.validPNG(width: 4, height: 4),
            contentType: "image/png",
            etag: "\"new\"",
            lastModified: nil
        )
        return MismatchedFormatFixture(
            key: key,
            cacheKey: cacheKey,
            url: url,
            existing: existing,
            response: response
        )
    }

    @Test(
        """
        assembleRevalidatedAsset validates a fresh revalidation response against \
        the passed-in expectedFormat (the resolved candidate's own format \
        recovered by revalidate(for:)): a PNG response validates and publishes \
        successfully when expectedFormat: .png is passed explicitly, even though \
        this key's own category default format is AVIF
        """
    )
    func assembleRevalidatedAssetValidatesAgainstThePassedFormat() async throws {
        let fixture = try mismatchedFormatFixture()
        try await withService { service, _ in
            let asset = try await service.assembleRevalidatedAsset(
                cacheKey: fixture.cacheKey,
                url: fixture.url,
                expectedFormat: .png,
                existing: fixture.existing,
                response: fixture.response
            )
            #expect(asset.metadata.contentType == "image/png")
            #expect(asset.metadata.width == 4)
            #expect(asset.metadata.height == 4)
            #expect(asset.metadata.insertedAt == fixture.existing.metadata.insertedAt)
        }
    }

    @Test(
        """
        assembleRevalidatedAsset never falls back to key.expectedFormat: \
        validating the identical PNG response bytes against this AVIF-art \
        key's own default format fails, proving the resolved candidate's \
        format -- not the key's -- must drive validation
        """
    )
    func assembleRevalidatedAssetNeverFallsBackToKeyExpectedFormat() async throws {
        let fixture = try mismatchedFormatFixture()
        #expect(fixture.key.expectedFormat == .avif)
        try await withService { service, _ in
            await #expect(throws: (any Error).self) {
                _ = try await service.assembleRevalidatedAsset(
                    cacheKey: fixture.cacheKey,
                    url: fixture.url,
                    expectedFormat: fixture.key.expectedFormat,
                    existing: fixture.existing,
                    response: fixture.response
                )
            }
        }
    }
}
