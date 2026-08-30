@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves ``AssetCacheService/evictAll()`` durably fences *every* other
/// independently-wired service instance sharing the same on-disk cache
/// directory -- not merely its own in-process `globalGeneration` -- against
/// publishing a network response whose fetch began before the clear but
/// only resolves after it.
///
/// Before the durable clear-epoch mechanism
/// (`SecureCacheDirectory+ClearEpoch.swift`), each ``AssetCacheService``
/// instance tracked "has a clear happened" purely via its own private
/// `globalGeneration` counter, bumped only by that exact instance's own
/// ``AssetCacheService/evictAll()`` call. Two independently constructed
/// service instances sharing one on-disk directory -- exactly as two
/// separate OS processes (or, as modeled here, two separate in-process
/// service graphs, each with its own private memory cache and its own
/// private ``AssetDiskCache`` actor instance) would -- each kept their own
/// copy of that counter; neither instance's clear ever bumped the other's.
/// An instance whose fetch was issued *before* a sibling instance's
/// `evictAll()`, but whose network response only arrives (and is only
/// ready to publish) *after* that clear has already returned, had no way
/// to learn a clear had happened at all, and would publish into (and later
/// serve from) its own untouched memory/disk state as if nothing had
/// happened -- even though the shared cache directory this represents was
/// just told to forget everything.
@Suite("AssetCacheService durable cross-service clear epoch")
struct AssetCacheServiceDurableClearEpochTests {
    private func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("DurableClearEpochScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private func standardLimits() -> AssetCacheLimits {
        AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 10_000_000,
            diskBudgetBytes: 10_000_000
        )
    }

    /// A fresh, independently-wired ``AssetCacheService`` (its own
    /// ``AssetMemoryCache``, its own ``AssetDiskCache`` actor instance, its
    /// own ``FakeAssetTransport``) sharing only `directory` on disk with
    /// any sibling instance created the same way -- modeling two separate
    /// OS processes (or two otherwise-unrelated service graphs in one
    /// process) that never share any in-memory state with each other at
    /// all.
    private func makeIndependentService(
        directory: URL,
        limits: AssetCacheLimits
    ) throws -> (service: AssetCacheService, transport: FakeAssetTransport) {
        let transport = FakeAssetTransport()
        let diskCache = try AssetDiskCache(directory: directory, limits: limits)
        let memoryCache = AssetMemoryCache(limits: limits)
        let service = AssetCacheService(
            memoryCache: memoryCache,
            diskCache: diskCache,
            transport: transport,
            digest: FakeDigestLookup(),
            limits: limits
        )
        return (service, transport)
    }

    private func cardArtKey(_ rawCardCode: String = "01001") throws -> AssetKey {
        let identifier = try AssetIdentifier.cardCode(rawCardCode)
        return AssetKey(category: .card(.art, identifier))
    }

    private func candidateURLs(for key: AssetKey) -> [URL] {
        AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            .map { $0.url(base: key.source) }
    }

    private func successResult(
        body: Data = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
    ) -> AssetHTTPResult {
        .success(AssetHTTPResponse(
            body: body,
            contentType: "image/avif",
            etag: nil,
            lastModified: nil
        ))
    }

    @Test(
        """
        A fetch issued on one service instance before a completely independent sibling \
        instance -- sharing only the same on-disk cache directory, with no shared \
        in-memory state at all -- calls evictAll() to completion must not publish once its \
        held network response is finally released, even though its own fetch began first: \
        the durable, cross-instance clear epoch must fence it, since its own private \
        globalGeneration was never bumped by the sibling's clear
        """
    )
    func siblingInstanceEvictAllFencesInFlightFetchAcrossInstances() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let (serviceA, transportA) = try makeIndependentService(
                directory: directory,
                limits: limits
            )
            let (serviceB, _) = try makeIndependentService(directory: directory, limits: limits)

            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transportA.enqueue(.success(successResult()), for: urls[0])
            await transportA.hold(urls[0])

            let fetchTask = Task<CachedAsset, Error> {
                try await serviceA.asset(for: key)
            }
            await transportA.waitForCallCount(1, for: urls[0])

            // Instance B has no in-memory knowledge of instance A's
            // in-flight fetch at all -- this is the whole point: it clears
            // *its own* memory cache (empty) and the *shared* on-disk
            // directory, then durably records that clear before returning.
            await serviceB.evictAll()

            // Only now does instance A's held network response resolve --
            // strictly after B's clear has already fully committed.
            await transportA.release(urls[0])

            await #expect(throws: AssetError.staleOperation) {
                try await fetchTask.value
            }

            // The durable clear must also fence instance A's own *later*
            // requests for this same key, not merely the one caught mid-
            // flight above: a fresh lookup on A still finds nothing
            // servable pre-authorized purely from A's own (never-cleared)
            // in-process bookkeeping, and must genuinely re-fetch.
            await transportA.enqueue(.success(successResult()), for: urls[0])
            let refetched = try await serviceA.asset(for: key)
            #expect(refetched.payload == AssetImageFixtureBuilder.validAVIF(width: 4, height: 4))
            #expect(
                await transportA.callCount(for: urls[0]) == 2,
                """
                The second, post-clear request for this key must be a genuine new network \
                fetch, not served from any state the pre-clear, now-superseded operation left \
                behind
                """
            )
        }
    }
}
