@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Candidate-walk, cache-hit, and in-flight-coalescing behavior for
/// ``AssetCacheService``. Conditional-revalidation (`If-None-Match`/304)
/// coverage is split into `AssetCacheServiceRevalidationTests.swift` (an
/// `extension AssetCacheServiceTests`, reusing the helpers below) purely to
/// stay under SwiftLint's `type_body_length`, the same way `AppModelTests`
/// is split by concern across sibling files.
@Suite("AssetCacheService")
struct AssetCacheServiceTests {
    /// A fresh scratch directory per test for the disk cache layer, nested
    /// under this package's own build output (never `/tmp`), removed
    /// unconditionally when the test finishes.
    ///
    /// Not `private`: shared with the `extension AssetCacheServiceTests`
    /// test groups split across sibling files in this directory (see
    /// ``AssetCacheServiceRevalidationTests``).
    func withService(
        transport: FakeAssetTransport = FakeAssetTransport(),
        digest: any LocalizedDigestLookup = FakeDigestLookup(),
        limits: AssetCacheLimits = AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 10_000_000,
            diskBudgetBytes: 10_000_000
        ),
        _ body: (AssetCacheService, FakeAssetTransport) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("CacheServiceScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let memoryCache = AssetMemoryCache(limits: limits)
        let diskCache = try AssetDiskCache(directory: root, limits: limits)
        let service = AssetCacheService(
            memoryCache: memoryCache,
            diskCache: diskCache,
            transport: transport,
            digest: digest,
            limits: limits
        )
        try await body(service, transport)
    }

    func cardArtKey(_ rawCardCode: String = "01001") throws -> AssetKey {
        let identifier = try AssetIdentifier.cardCode(rawCardCode)
        return AssetKey(category: .card(.art, identifier))
    }

    func candidateURLs(
        for key: AssetKey,
        digest: any LocalizedDigestLookup = FakeDigestLookup()
    ) -> [URL] {
        AssetLocator.candidates(for: key, digest: digest).map { $0.url(base: key.source) }
    }

    func successResult(
        body: Data = AssetImageFixtureBuilder.syntheticAVIF(width: 4, height: 4),
        etag: String? = nil,
        lastModified: String? = nil
    ) -> AssetHTTPResult {
        .success(AssetHTTPResponse(
            body: body,
            contentType: "image/avif",
            etag: etag,
            lastModified: lastModified
        ))
    }

    // MARK: - Candidate walk

    @Test("A 404 on the first candidate advances to the second, which succeeds")
    func candidateWalkAdvancesOn404() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            #expect(
                urls.count >= 2,
                "This test needs at least 2 candidates (localized/english + alternate front)"
            )
            await transport.enqueue(.success(.notFound), for: urls[0])
            await transport.enqueue(.success(successResult()), for: urls[1])

            let asset = try await service.asset(for: key)
            #expect(asset.payload == AssetImageFixtureBuilder.syntheticAVIF(width: 4, height: 4))
        }
    }

    @Test("Every candidate returning 404 exhausts the chain with a typed error")
    func everyCandidateNotFoundExhaustsChain() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            for url in urls {
                await transport.enqueue(.success(.notFound), for: url)
            }

            await #expect(throws: AssetError.candidatesExhausted) {
                _ = try await service.asset(for: key)
            }
        }
    }

    @Test(
        "A non-404 transport failure on the first candidate is terminal and never advances"
    )
    func nonNotFoundErrorIsTerminal() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(
                .failure(AssetError.transportFailure("connection reset")),
                for: urls[0]
            )
            // Deliberately do NOT enqueue anything for urls[1]; if the
            // service wrongly advanced past the failure, it would throw
            // .unexpectedStatus(599) from the fake's "no script" fallback
            // instead of propagating the real transport failure.

            await #expect(throws: AssetError.transportFailure("ignored")) {
                _ = try await service.asset(for: key)
            }
            let secondCandidateCallCount = await transport.callCount(for: urls[1])
            #expect(
                secondCandidateCallCount == 0,
                "A non-404 failure must not advance the candidate chain"
            )
        }
    }

    @Test(
        "A resolved asset is cached: a second request for the same key makes no further network hit"
    )
    func resolvedAssetIsCachedAcrossCalls() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(successResult()), for: urls[0])

            _ = try await service.asset(for: key)
            _ = try await service.asset(for: key)
            let callCount = await transport.callCount(for: urls[0])
            #expect(callCount == 1)
        }
    }

    // MARK: - Coalescing

    @Test("Two concurrent identical requests are coalesced onto a single network fetch")
    func concurrentIdenticalRequestsCoalesce() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.hold(urls[0])
            await transport.enqueue(.success(successResult()), for: urls[0])

            async let first = service.asset(for: key)
            async let second = service.asset(for: key)
            // Coalescing means only one real network fetch ever starts;
            // wait for that single fetch to begin, then give the second
            // caller time to join the in-flight work rather than starting
            // its own (which would show up as a second call once released).
            await transport.waitForCallCount(1, for: urls[0])
            try await Task.sleep(nanoseconds: 20_000_000)
            await transport.release(urls[0])

            let (firstResult, secondResult) = try await (first, second)
            #expect(firstResult.payload == secondResult.payload)
            let callCount = await transport.callCount(for: urls[0])
            #expect(
                callCount == 1,
                "Only one network fetch should have started for two identical concurrent requests"
            )
        }
    }

    @Test("One waiter cancelling does not corrupt or cancel the shared fetch for the other waiter")
    func oneWaiterCancellingDoesNotAffectOthers() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.hold(urls[0])
            await transport.enqueue(.success(successResult()), for: urls[0])

            let firstTask = Task { try await service.asset(for: key) }
            let secondTask = Task { try await service.asset(for: key) }
            await transport.waitForCallCount(1, for: urls[0])
            try await Task.sleep(nanoseconds: 20_000_000)

            firstTask.cancel()
            // Give the cancellation handler a moment to run and decrement
            // the waiter count before releasing the held fetch.
            try await Task.sleep(nanoseconds: 20_000_000)
            await transport.release(urls[0])

            let secondResult = try await secondTask.value
            #expect(secondResult.payload == AssetImageFixtureBuilder.syntheticAVIF(
                width: 4,
                height: 4
            ))
            let callCount = await transport.callCount(for: urls[0])
            #expect(callCount == 1, "The shared fetch must not have been restarted or duplicated")
        }
    }

    @Test("The last waiter cancelling stops the fetch and leaves no cache entry behind")
    func lastWaiterCancellingLeavesNoCacheEntry() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.hold(urls[0])
            await transport.enqueue(.success(successResult()), for: urls[0])

            let onlyTask = Task { try await service.asset(for: key) }
            await transport.waitForCallCount(1, for: urls[0])
            try await Task.sleep(nanoseconds: 20_000_000)

            onlyTask.cancel()
            let result = await onlyTask.result
            #expect(throws: (any Error).self) { try result.get() }

            // Release afterward so the fake transport's internal polling
            // loop doesn't spin forever; the fetch's own task should
            // already have been cancelled by this point regardless.
            await transport.release(urls[0])

            let secondAttempt = try await service.asset(for: key)
            #expect(
                secondAttempt.payload == AssetImageFixtureBuilder
                    .syntheticAVIF(width: 4, height: 4),
                "A later, independent request must still succeed normally"
            )
        }
    }
}
