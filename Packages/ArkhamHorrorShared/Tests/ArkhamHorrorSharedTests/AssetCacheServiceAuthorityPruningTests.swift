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

    /// Issues a fresh authority token for `key` and stamps it with both
    /// halves of its durable authority (clear epoch and disk write
    /// generation) exactly the way every real call site now does via
    /// ``AssetCacheService/beginIssuance(for:)`` — no real caller ever
    /// checks ``AssetCacheService/isAuthoritative(_:for:)`` against a
    /// token that skipped this stamp, so every test in this file that
    /// bypasses the full fetch/revalidation pipeline to exercise pruning
    /// in isolation must reproduce it too, or every check below would
    /// trivially fail regardless of pruning, for an unrelated reason.
    func stampedToken(
        for service: AssetCacheService,
        key: AssetCacheKey
    ) async -> AssetCacheService.CacheToken {
        let authority = await service.beginIssuance(for: key)
        var token = await service.issueToken(for: key)
        token.durableClearEpoch = authority.clearEpoch
        token.diskAuthorityID = authority.diskAuthorityID
        return token
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
                try await service.invalidate(cacheKey)
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
            // ``issueToken(for:)`` alone never carries durable-clear-epoch
            // authority (see its own doc comment): every real caller only
            // ever checks ``isAuthoritative(_:for:)`` against a token that
            // has already been stamped via ``beginIssuance(for:)`` first.
            // This test bypasses the full fetch/revalidation pipeline
            // entirely to exercise pruning in isolation, so it must stamp
            // both tokens itself (see ``stampedToken(for:key:)`` above) to
            // faithfully model real usage -- otherwise every check below
            // would trivially fail regardless of pruning, for an
            // unrelated reason.
            let firstToken = await stampedToken(for: service, key: firstKey)

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
            let freshToken = await stampedToken(for: service, key: firstKey)
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

    @Test(
        """
        A brand-new key touched for the very first time while every other tracked key is \
        genuinely busy is never pruned by that same triggering call, even before its caller \
        has had any chance to record it as busy itself -- and issueToken(for:) never leaves \
        a key's latest token orphaned outside authorityKeyOrder/trackedAuthorityKeys as a \
        result
        """
    )
    func newlyTouchedKeyIsNeverPrunedByItsOwnRegisteringCall() async throws {
        try await withService { service, _ in
            // Fill tracking to exactly capacity, holding every one of
            // those keys open ("busy") via an authority window so none
            // of them is a legitimate prune candidate -- this reproduces
            // "every other key busy" without the cost of driving that
            // many real network fetches through `FakeAssetTransport`.
            var busyKeys: [AssetCacheKey] = []
            for index in 0 ..< AssetCacheService.maxTrackedAuthorityKeys {
                let rawCode = String(format: "%06d", index)
                let cacheKey = try distinctCacheKey(rawCode)
                await service.beginAuthorityWindow(for: cacheKey)
                busyKeys.append(cacheKey)
            }

            // Tracking is now exactly at capacity, every entry busy.
            let orderCountBefore = await service.authorityKeyOrder.count
            #expect(orderCountBefore == AssetCacheService.maxTrackedAuthorityKeys)

            // A brand-new key's very first touch, via issueToken(for:),
            // triggers a prune pass while it itself is the only
            // non-busy-yet entry present (its own `keyLatestToken` write
            // has not even happened yet at the moment pruning runs). The
            // old, unprotected pruning pass would prune this exact key
            // right back out before `issueToken(for:)` ever got to write
            // it, silently orphaning its subsequent `keyLatestToken`
            // entry outside `authorityKeyOrder`/`trackedAuthorityKeys`
            // forever.
            let newKey = try distinctCacheKey(String(format: "%06d", 900_000))
            let newToken = await service.issueToken(for: newKey)

            let trackedAfter = await service.trackedAuthorityKeys.contains(newKey)
            #expect(trackedAfter, "the newly touched key must remain tracked, not orphaned")

            let latestToken = await service.keyLatestToken[newKey]
            #expect(latestToken == newToken)

            // Every busy key must also still be intact: none of them were
            // wrongly evicted just because tracking now (safely) exceeds
            // the nominal capacity by exactly one during this burst.
            for cacheKey in busyKeys {
                let stillTracked = await service.trackedAuthorityKeys.contains(cacheKey)
                #expect(stillTracked, "a genuinely busy key must never be pruned")
            }
        }
    }

    @Test(
        """
        Repeatedly touching keys while tracking sits at capacity with every existing key \
        busy keeps authorityKeyOrder bounded to capacity plus the busy backlog (rather than \
        growing forever from popped-but-never-reclaimed prefix slots), proving this queue's \
        own append/pop cost stays O(1) amortized underneath the (separately documented, \
        inherent) full-busy-backlog rescan every touch already performs while nothing is \
        prunable
        """
    )
    func sustainedBusyBurstKeepsQueueOrderBounded() async throws {
        try await withService { service, _ in
            var busyKeys: [AssetCacheKey] = []
            for index in 0 ..< AssetCacheService.maxTrackedAuthorityKeys {
                let rawCode = String(format: "%06d", index)
                let cacheKey = try distinctCacheKey(rawCode)
                await service.beginAuthorityWindow(for: cacheKey)
                busyKeys.append(cacheKey)
            }

            // Only a modest number of touches beyond capacity -- each one
            // still forces a full requeue pass over every busy key ahead
            // of it in the queue (the reviewer-cited workload), but this
            // stays fast since this queue's own append/pop is O(1)
            // amortized rather than `Array.removeFirst()`'s O(n) shift.
            let extraTouches = 200
            for index in 0 ..< extraTouches {
                let rawCode = String(format: "%06d", index + 500_000)
                let cacheKey = try distinctCacheKey(rawCode)
                _ = await service.issueToken(for: cacheKey)
                try await service.invalidate(cacheKey)
            }

            let orderCount = await service.authorityKeyOrder.count
            #expect(orderCount <= busyKeys.count + extraTouches)

            for cacheKey in busyKeys {
                let stillTracked = await service.trackedAuthorityKeys.contains(cacheKey)
                #expect(stillTracked, "a genuinely busy key must never be pruned")
            }
        }
    }

    @Test(
        """
        Touching many distinct keys against a large in-flight-revalidation busy backlog \
        (registered via setInFlightRevalidation(_:for:), not merely an authority window) \
        keeps each individual isAuthorityKeyBusy(_:)'s revalidation check to the same \
        single keyed revalidationKeyRefCount lookup as an identical churn against a tiny \
        busy backlog -- proving that check is O(1) per considered key, not an O(m) scan \
        of every currently in-flight revalidation slot. Every busy key, in both the small \
        and large backlog, is also proven to never be pruned by the churn.
        """
    )
    func manyInFlightRevalidationsStayBusyAndUseConstantPerKeyBusyChecks() async throws {
        let smallObservation = try await observeChurnAgainstRevalidationBacklog(
            busyKeyCount: 8,
            touchCount: 300,
            keyPrefix: 1
        )
        let largeObservation = try await observeChurnAgainstRevalidationBacklog(
            busyKeyCount: AssetCacheService.maxTrackedAuthorityKeys,
            touchCount: 300,
            keyPrefix: 2
        )

        #expect(smallObservation.metrics.busyCheckCount > 0)
        #expect(largeObservation.metrics.busyCheckCount > 0)
        #expect(
            smallObservation.metrics.revalidationKeyRefCountLookupCount
                == smallObservation.metrics.busyCheckCount,
            "Small-backlog busy checks should each reach exactly one refcount lookup"
        )
        #expect(
            largeObservation.metrics.revalidationKeyRefCountLookupCount
                == largeObservation.metrics.busyCheckCount,
            "Large-backlog busy checks should each reach exactly one refcount lookup"
        )
        #expect(
            largeObservation.metrics.maxRevalidationEntriesInspectedPerCheck
                == smallObservation.metrics.maxRevalidationEntriesInspectedPerCheck,
            """
            A busy check against \(largeObservation.busyKeyCount) in-flight revalidation keys \
            must inspect no more revalidation entries than the same check against \
            \(smallObservation.busyKeyCount) keys
            """
        )
        #expect(
            largeObservation.metrics.maxRevalidationEntriesInspectedPerCheck == 1,
            "isAuthorityKeyBusy(_:)'s revalidation path must remain one keyed refcount lookup"
        )
    }
}
