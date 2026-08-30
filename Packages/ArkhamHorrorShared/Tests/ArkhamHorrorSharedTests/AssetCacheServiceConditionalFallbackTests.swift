@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of the final cumulative review's finding
/// #2: a disk hit's conditional revalidation receiving an authoritative,
/// successfully-invalidated 404 for its own resolved candidate must not
/// be treated as if `key`'s *entire* candidate chain were exhausted.
/// ``AssetCacheService/asset(for:)``'s disk-hit branch only ever issues a
/// conditional request against the *one* candidate the disk entry was
/// previously resolved to; any other candidates for the same key (an
/// English fallback, or an alternate-front image) were never even
/// requested, so their availability must not depend on whether a
/// *different*, previously cached variant happens to still be on disk.
///
/// Split from `AssetCacheServiceTests.swift` purely for `file_length`,
/// reusing its `cardArtKey`/`candidateURLs`/`successResult` helpers and
/// `AssetCacheServicePersistenceTests`'s `ServiceLayers`/`makeService`
/// helpers for direct multi-instance `AssetDiskCache` sharing (an empty
/// memory cache in front of an already-populated disk, forcing
/// `asset(for:)` onto its disk-hit branch rather than a plain memory
/// short-circuit).
extension AssetCacheServiceTests {
    @Test(
        """
        A disk hit's conditional revalidation receiving an authoritative 404 for its own \
        resolved candidate continues the ordinary candidate walk at the next candidate, \
        rather than reporting the whole chain exhausted
        """
    )
    func conditional404OnDiskHitAdvancesToNextCandidateRatherThanExhausting() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            #expect(
                urls.count >= 2,
                "This test needs at least 2 candidates so the fallback walk has somewhere to go"
            )
            let staleBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)

            // Seed a real, fully-published disk entry resolved to
            // `urls[0]` (with an ETag, so it is eligible for conditional
            // revalidation) through a first, freshly-wired service —
            // discarded afterward so its own memory cache plays no
            // further part.
            let seedLayers = try makeService(directory: root, limits: limits)
            await seedLayers.transport.enqueue(
                .success(successResult(body: staleBody, etag: "\"v1\"")),
                for: urls[0]
            )
            let seeded = try await seedLayers.service.asset(for: key)
            #expect(seeded.payload == staleBody)

            // A second, independently-wired service reusing the same
            // underlying `AssetDiskCache` with an empty memory cache,
            // forcing `asset(for:)` onto its disk-hit branch.
            let layers = makeService(diskCache: seedLayers.diskCache, limits: limits)

            // The server has genuinely stopped serving `urls[0]` (the
            // resolved candidate this disk entry was cached from) --
            // an authoritative, definitive 404 -- but `urls[1]` (this
            // key's next candidate) is still perfectly available.
            await layers.transport.enqueue(.success(.notFound), for: urls[0])
            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 6, height: 6)
            await layers.transport.enqueue(
                .success(successResult(body: freshBody, etag: "\"v2\"")),
                for: urls[1]
            )

            let resolved = try await layers.service.asset(for: key)
            #expect(
                resolved.payload == freshBody,
                """
                A 404 confirmed only for this key's first resolved candidate must not block \
                falling through to its still-available next candidate
                """
            )

            // Exactly one request was made to the now-confirmed-gone
            // candidate (the conditional revalidation itself) -- no
            // duplicate/retry request against it as part of the
            // fallback walk.
            #expect(await layers.transport.callCount(for: urls[0]) == 1)
            #expect(await layers.transport.callCount(for: urls[1]) == 1)
        }
    }

    @Test(
        """
        A disk hit's conditional revalidation receiving an authoritative 404 for its own \
        LAST resolved candidate still reports genuine exhaustion, not a resurrected fallback
        """
    )
    func conditional404OnDiskHitsLastCandidateStillReportsExhaustion() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let staleBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            let lastURL = try #require(urls.last)

            let seedLayers = try makeService(directory: root, limits: limits)
            await seedLayers.transport.enqueue(
                .success(successResult(body: staleBody, etag: "\"v1\"")),
                for: lastURL
            )
            // Every earlier candidate 404s during the initial seed so the
            // disk entry actually resolves to (and persists) `lastURL`.
            for url in urls.dropLast() {
                await seedLayers.transport.enqueue(.success(.notFound), for: url)
            }
            let seeded = try await seedLayers.service.asset(for: key)
            #expect(seeded.payload == staleBody)

            let layers = makeService(diskCache: seedLayers.diskCache, limits: limits)
            await layers.transport.enqueue(.success(.notFound), for: lastURL)

            await #expect(throws: AssetError.candidatesExhausted) {
                _ = try await layers.service.asset(for: key)
            }
        }
    }
}
