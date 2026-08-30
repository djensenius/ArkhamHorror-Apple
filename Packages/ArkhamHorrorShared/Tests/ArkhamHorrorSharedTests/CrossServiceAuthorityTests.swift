@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Full-stack (``AssetCacheService/asset(for:)`` entrypoint, not the
/// lower-level ``AssetDiskCache`` unit coverage in
/// `AssetDiskCacheWriteGenerationTests.swift`) coverage for the specific
/// cross-service scenarios a cumulative review round flagged as still
/// open even after the durable clear-epoch mechanism landed:
///
/// 1. A sibling service's `evictAll()` must invalidate a *memory-resident*
///    entry another, completely independent service already published --
///    not merely fence an in-flight fetch still awaiting its network
///    response (already covered by
///    `AssetCacheServiceDurableClearEpochTests`).
/// 2. Two independent services' per-key write ordering must be governed
///    by the durable, disk-persisted write generation -- not either
///    service's own private, actor-local bookkeeping -- so an older
///    service's delayed publish can never overwrite a newer sibling's
///    already-applied one, and vice versa.
@Suite("AssetCacheService cross-service authority")
struct CrossServiceAuthorityTests {
    private func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("CrossServiceAuthorityScratch", isDirectory: true)
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
        Service B's evictAll() must invalidate an entry service A already fully published to \
        its own memory cache (not merely fence a fetch A still has in flight): a subsequent \
        memory hit on A, for the exact same key, must not be trusted purely from A's own \
        untouched in-process bookkeeping, and must instead genuinely re-fetch
        """
    )
    func siblingClearInvalidatesAlreadyPublishedMemoryEntry() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let (serviceA, transportA) = try makeIndependentService(
                directory: directory,
                limits: limits
            )
            let (serviceB, _) = try makeIndependentService(directory: directory, limits: limits)

            let key = try cardArtKey()
            let urls = candidateURLs(for: key)

            // A fully publishes -- no held response, no suspension left
            // open at all -- so this exercises a plain, already-resolved
            // memory hit, not a race against an in-flight operation.
            await transportA.enqueue(.success(successResult()), for: urls[0])
            let firstFetch = try await serviceA.asset(for: key)
            #expect(firstFetch.payload == AssetImageFixtureBuilder.validAVIF(width: 4, height: 4))
            #expect(await transportA.callCount(for: urls[0]) == 1)

            // B, sharing no in-memory state with A at all, clears the
            // shared on-disk directory and durably records that clear.
            await serviceB.evictAll()

            // A's own next lookup for this exact key must not trust its
            // already-published memory entry: the durable clear epoch it
            // was stamped with no longer matches current.
            await transportA.enqueue(.success(successResult()), for: urls[0])
            let secondFetch = try await serviceA.asset(for: key)
            #expect(secondFetch.payload == AssetImageFixtureBuilder.validAVIF(width: 4, height: 4))
            #expect(
                await transportA.callCount(for: urls[0]) == 2,
                """
                A's second lookup must be a genuine new network fetch: its own memory-resident \
                entry from before B's clear must never be trusted merely because A's own \
                in-process bookkeeping was never itself invalidated
                """
            )
        }
    }

    @Test(
        """
        An older-issued fetch on service A, held up in the network layer, must not overwrite \
        a newer, already-published fetch service B independently completed first for the \
        exact same key -- A's own publish attempt must instead fail as stale, and the disk \
        entry a later, fresh service sees must be B's
        """
    )
    func olderIssuedFetchCannotOverwriteNewerSiblingFetch() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let (serviceA, transportA) = try makeIndependentService(
                directory: directory,
                limits: limits
            )
            let (serviceB, transportB) = try makeIndependentService(
                directory: directory,
                limits: limits
            )

            let key = try cardArtKey()
            let urls = candidateURLs(for: key)

            let payloadA = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            let payloadB = AssetImageFixtureBuilder.validAVIF(width: 8, height: 8)

            await transportA.enqueue(.success(successResult(body: payloadA)), for: urls[0])
            await transportA.hold(urls[0])
            let fetchTaskA = Task<CachedAsset, Error> {
                try await serviceA.asset(for: key)
            }
            await transportA.waitForCallCount(1, for: urls[0])

            // B independently completes a full fetch/publish for the same
            // key while A's own response is still held.
            await transportB.enqueue(.success(successResult(body: payloadB)), for: urls[0])
            let completedB = try await serviceB.asset(for: key)
            #expect(completedB.payload == payloadB)

            // Only now does A's held response resolve -- strictly after
            // B's newer write has already durably landed.
            await transportA.release(urls[0])
            let resultA = try await fetchTaskA.value
            #expect(
                resultA.payload == payloadA,
                "A's own in-process view of its own fetch's result is unaffected by B's publish"
            )

            // The disk entry itself -- the shared, durable resource both
            // services actually write through -- must still hold B's
            // bytes: A's own (older-issued, later-completing) publish
            // attempt must have been rejected as stale by the durable
            // per-key write-generation CAS, never overwriting B's.
            // Inspected directly through a brand-new ``AssetDiskCache``
            // instance over the same directory (rather than through a
            // full ``AssetCacheService.asset(for:)`` round trip, which
            // would require -- entirely separately from what this test
            // is proving -- a scripted mandatory online conditional
            // revalidation before ever trusting a disk-only hit at all).
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let inspectionCache = try AssetDiskCache(directory: directory, limits: limits)
            let onDisk = try #require(try await inspectionCache.get(cacheKey))
            #expect(
                onDisk.payload == payloadB,
                "The durable disk entry must remain B's newer, already-applied publish"
            )
        }
    }
}
