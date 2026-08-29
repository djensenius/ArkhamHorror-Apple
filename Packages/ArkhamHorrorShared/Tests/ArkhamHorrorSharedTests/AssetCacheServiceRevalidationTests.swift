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
}
