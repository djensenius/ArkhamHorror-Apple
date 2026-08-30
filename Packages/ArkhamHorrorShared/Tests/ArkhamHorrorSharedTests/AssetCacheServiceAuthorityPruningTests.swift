@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Bounded-growth coverage for ``AssetCacheService``'s per-key authority
/// bookkeeping (``AssetCacheService/keyLatestToken``/
/// ``keyClearGeneration``, pruned by
/// ``AssetCacheService/noteAuthorityKeyTouched(_:)`` in
/// `AssetCacheService+Epoch.swift`).
///
/// Every one of those two dictionaries is keyed by an
/// ``AssetCacheKey`` ultimately derived from a self-hosted server's or a
/// homebrew campaign/card's identifier — server-controlled or
/// user-supplied input, not a small first-party enumeration — so without
/// pruning, a caller that ever requests enough distinct never-repeated
/// keys grows every one of these maps without bound for the remaining
/// lifetime of the process. (``AssetCacheService/nextGlobalIssuance``
/// itself is a single, unbounded-but-`O(1)`-space counter shared across
/// every key -- never per-key -- so it has no growth to bound; only the
/// per-key maps below need this coverage.) Split into its own file
/// (rather than folded into `AssetCacheServiceTests.swift`) purely to
/// stay under SwiftLint's `type_body_length`, matching this directory's
/// existing convention.
extension AssetCacheServiceTests {
    /// Issues a fresh authority token directly (bypassing the full
    /// network-fetch pipeline entirely) for a synthetic cache key derived
    /// from `rawCardCode`, purely so this file's bounded-growth tests can
    /// exercise ``AssetCacheService/issueToken(for:)``'s pruning behavior
    /// at high key cardinality without the cost (or nondeterminism) of
    /// actually driving thousands of scripted network round trips through
    /// `FakeAssetTransport`.
    func distinctCacheKey(_ rawCardCode: String) throws -> AssetCacheKey {
        let key = try cardArtKey(rawCardCode)
        let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
        return AssetCacheKey(for: key, candidates: candidates)
    }

    @Test(
        """
        Requesting far more distinct keys than maxTrackedAuthorityKeys keeps every one \
        of keyLatestToken/keyClearGeneration bounded, rather than growing \
        without limit for the lifetime of the process
        """
    )
    func authorityBookkeepingStaysBoundedAcrossManyDistinctKeys() async throws {
        try await withService { service, _ in
            let distinctKeyCount = AssetCacheService.maxTrackedAuthorityKeys + 500
            for index in 0 ..< distinctKeyCount {
                let rawCode = String(format: "%06d", index)
                let cacheKey = try distinctCacheKey(rawCode)
                _ = await service.issueToken(for: cacheKey)
                // Every issued key also observes an invalidate() (as a
                // definitive-404 quarantine or a quarantine-on-quarantine
                // would), so keyClearGeneration's own growth is exercised
                // by the exact same loop rather than needing a second,
                // separate pass over just as many keys.
                await service.invalidate(cacheKey)
            }

            let latestTokenCount = await service.keyLatestToken.count
            let clearGenerationCount = await service.keyClearGeneration.count
            let orderCount = await service.authorityKeyOrder.count
            let trackedCount = await service.trackedAuthorityKeys.count

            #expect(latestTokenCount <= AssetCacheService.maxTrackedAuthorityKeys)
            #expect(clearGenerationCount <= AssetCacheService.maxTrackedAuthorityKeys)
            #expect(orderCount <= AssetCacheService.maxTrackedAuthorityKeys)
            #expect(trackedCount == orderCount)
        }
    }

    @Test("A pruned key's bookkeeping is fully self-consistent when it is requested again")
    func prunedKeyRestartsCleanlyOnFreshRequest() async throws {
        try await withService { service, _ in
            let firstKey = try distinctCacheKey("000001")
            let firstToken = await service.issueToken(for: firstKey)

            for index in 0 ..< (AssetCacheService.maxTrackedAuthorityKeys + 50) {
                let rawCode = String(format: "%06d", index + 100_000)
                let cacheKey = try distinctCacheKey(rawCode)
                _ = await service.issueToken(for: cacheKey)
            }

            // The very first key was the least-recently-touched entry, so
            // it must have been pruned by now: its old token is no longer
            // authoritative (there is nothing left to check it against).
            let firstStillAuthoritative = await service.isAuthoritative(firstToken, for: firstKey)
            #expect(!firstStillAuthoritative)

            // Requesting the exact same key again must behave exactly
            // like the very first time it was ever seen: a fresh token is
            // issued and is immediately, unconditionally authoritative.
            let freshToken = await service.issueToken(for: firstKey)
            let freshIsAuthoritative = await service.isAuthoritative(freshToken, for: firstKey)
            #expect(freshIsAuthoritative)
        }
    }

    @Test(
        """
        A key with a genuinely in-flight fetch is never pruned, even while enough other \
        distinct keys are touched in between to force pruning to run repeatedly -- \
        otherwise a live fetch would spuriously find itself no longer authoritative \
        purely due to unrelated keys' churn, and would silently fail to publish
        """
    )
    func busyKeyNeverPrunedDuringChurn() async throws {
        try await withService { service, transport in
            let busyKey = try cardArtKey("000001")
            let busyCacheKey = try distinctCacheKey("000001")
            let urls = candidateURLs(for: busyKey)
            let busyURL = urls[0]
            await transport.enqueue(.success(successResult()), for: busyURL)
            await transport.hold(busyURL)

            let inFlightFetch = Task { try await service.asset(for: busyKey) }
            await transport.waitForCallCount(1, for: busyURL)

            // The fetch is now genuinely in-flight (registered in
            // ``AssetCacheService/inFlight``, held mid-network-call) for
            // as long as this loop runs, since nothing here ever releases
            // `busyURL`.
            for index in 0 ..< (AssetCacheService.maxTrackedAuthorityKeys + 500) {
                let rawCode = String(format: "%06d", index + 200_000)
                let cacheKey = try distinctCacheKey(rawCode)
                _ = await service.issueToken(for: cacheKey)
            }

            let stillTrackedDuringChurn = await service.keyLatestToken[busyCacheKey] != nil
            #expect(stillTrackedDuringChurn, "a genuinely in-flight key must never be pruned")

            await transport.release(busyURL)
            let asset = try await inFlightFetch.value
            #expect(asset.payload == AssetImageFixtureBuilder.validAVIF(width: 4, height: 4))
        }
    }
}
