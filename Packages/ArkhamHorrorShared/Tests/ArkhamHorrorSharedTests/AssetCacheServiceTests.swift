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
    /// A fresh scratch directory per test, nested under this package's own
    /// build output (never `/tmp`), removed unconditionally when the test
    /// finishes.
    ///
    /// Not `private`: shared with the `extension AssetCacheServiceTests`
    /// test groups split across sibling files in this directory (see
    /// ``AssetCacheServiceRevalidationTests`` and
    /// ``AssetCacheServicePersistenceTests``, the latter of which builds
    /// its own `AssetDiskCache` directly over this directory with an
    /// injected `FileManager` subclass, rather than routing it through
    /// `withService` below — passing a non-`Sendable` `FileManager`
    /// subclass through an intervening closure parameter defeats the
    /// compiler's region-based "sending to an actor initializer" analysis
    /// even though the direct call site itself is provably safe).
    func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
        let rootParent = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("CacheServiceScratch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootParent,
            withIntermediateDirectories: true
        )
        let root = rootParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

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
        try await withScratchDirectory { root in
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
    }

    func cardArtKey(_ rawCardCode: String = "01001") throws -> AssetKey {
        let identifier = try AssetIdentifier.cardCode(rawCardCode)
        return AssetKey(category: .card(.art, identifier))
    }

    /// A PNG-expecting key (``AssetCategory/expectedFormat``), used by
    /// decode-gate tests that need a format whose pure metadata parser
    /// (unlike AVIF's) does not itself require ImageIO to already confirm
    /// a real coded image is present.
    func setIconKey(_ rawSetCode: String = "01") throws -> AssetKey {
        let identifier = try AssetIdentifier.setOrBoxCode(rawSetCode)
        return AssetKey(category: .setIcon(identifier, variant: nil))
    }

    /// A JPEG-expecting key (``AssetCategory/expectedFormat``), for the
    /// same reason as ``setIconKey(_:)``.
    func campaignBoxKey(_ rawSetCode: String = "01") throws -> AssetKey {
        let identifier = try AssetIdentifier.setOrBoxCode(rawSetCode)
        return AssetKey(category: .campaignBox(identifier))
    }

    func candidateURLs(
        for key: AssetKey,
        digest: any LocalizedDigestLookup = FakeDigestLookup()
    ) -> [URL] {
        AssetLocator.candidates(for: key, digest: digest).map { $0.url(base: key.source) }
    }

    func successResult(
        body: Data = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4),
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
            #expect(asset.payload == AssetImageFixtureBuilder.validAVIF(width: 4, height: 4))
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

    // MARK: - Decode gate (full platform decode before cache publication)

    @Test(
        """
        A PNG whose signature and IHDR declare plausible dimensions, but which has no \
        IDAT/IEND and so is not actually decodable, is rejected rather than cached
        """
    )
    func headerOnlyPNGRejectedRatherThanCached() async throws {
        try await withService { service, transport in
            let key = try setIconKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(
                .success(.success(AssetHTTPResponse(
                    body: AssetImageFixtureBuilder.pngHeaderOnly(width: 4, height: 4),
                    contentType: "image/png",
                    etag: nil,
                    lastModified: nil
                ))),
                for: urls[0]
            )

            await #expect(throws: AssetError.malformedImageData) {
                _ = try await service.asset(for: key)
            }
        }
    }

    @Test(
        """
        A JPEG whose SOI/SOF declare plausible dimensions, but which has no scan data or \
        EOI and so is not actually decodable, is rejected rather than cached
        """
    )
    func headerOnlyJPEGRejectedRatherThanCached() async throws {
        try await withService { service, transport in
            let key = try campaignBoxKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(
                .success(.success(AssetHTTPResponse(
                    body: AssetImageFixtureBuilder.jpegHeaderOnly(width: 4, height: 4),
                    contentType: "image/jpeg",
                    etag: nil,
                    lastModified: nil
                ))),
                for: urls[0]
            )

            await #expect(throws: AssetError.malformedImageData) {
                _ = try await service.asset(for: key)
            }
        }
    }

    @Test(
        """
        A malformed/undecodable payload that fails the decode gate never reaches the disk \
        or memory cache: a subsequent request for the same key still performs a fresh \
        network fetch rather than replaying a poisoned failure or a partial entry
        """
    )
    func decodeGateFailureNeverPublishesAndAllowsFreshRetry() async throws {
        try await withService { service, transport in
            let key = try setIconKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(
                .success(.success(AssetHTTPResponse(
                    body: AssetImageFixtureBuilder.pngHeaderOnly(width: 4, height: 4),
                    contentType: "image/png",
                    etag: nil,
                    lastModified: nil
                ))),
                for: urls[0]
            )
            await #expect(throws: AssetError.malformedImageData) {
                _ = try await service.asset(for: key)
            }

            await transport.enqueue(
                .success(.success(AssetHTTPResponse(
                    body: AssetImageFixtureBuilder.validPNG(width: 4, height: 4),
                    contentType: "image/png",
                    etag: nil,
                    lastModified: nil
                ))),
                for: urls[0]
            )
            let asset = try await service.asset(for: key)
            #expect(asset.payload == AssetImageFixtureBuilder.validPNG(width: 4, height: 4))
        }
    }

    // MARK: - decodeImageOffActor

    @Test(
        """
        decodeImageOffActor decodes a valid payload to a CGImage with the \
        expected dimensions, off the actor's own executor via a structured \
        `async let` child task
        """
    )
    func decodeImageOffActorDecodesValidPayload() async throws {
        try await withService { service, _ in
            let payload = AssetImageFixtureBuilder.validPNG(width: 4, height: 4)
            let decoded = try await service.decodeImageOffActor(payload)
            #expect(decoded.width == 4)
            #expect(decoded.height == 4)
        }
    }

    @Test(
        """
        decodeImageOffActor throws malformedImageData for a header-only, \
        non-decodable payload rather than crashing or silently returning a \
        blank image
        """
    )
    func decodeImageOffActorRejectsUndecodablePayload() async throws {
        try await withService { service, _ in
            let payload = AssetImageFixtureBuilder.pngHeaderOnly(width: 4, height: 4)
            await #expect(throws: AssetError.malformedImageData) {
                _ = try await service.decodeImageOffActor(payload)
            }
        }
    }
}
