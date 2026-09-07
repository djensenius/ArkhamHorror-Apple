@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic, white-box coverage for
/// ``AssetCacheService/memoryEntryStillCurrent(_:storedAuthorityID:for:)``'s
/// own gap-tolerance logic (`authorityGapIsEntirelyAbandoned(from:downTo:epoch:for:)`)
/// — a fix for a genuine hang this subsystem's own cancellation
/// contract otherwise produces: minting a fresh durable ``AuthorityID`` for a
/// key (``AssetCacheService/beginIssuance(for:)``/
/// ``AssetCacheService/beginRevalidationIssuance``)
/// -- happens the instant a fresh fetch/revalidation is *issued* —
/// strictly before it is known whether that operation will ever
/// complete. A prior revision of ``memoryEntryStillCurrent(_:storedAuthorityID:for:)``
/// compared a stored entry's own ``AssetMemoryCache/CachedAsset/authorityID``
/// against `key`'s current durable most-recently-issued identifier using plain
/// equality: the moment any later operation for that same key was
/// merely issued — even one immediately cancelled by its sole waiter,
/// before it ever reached a `publish`/`touch`/`invalidate` call — every
/// older, still-genuinely-current entry became permanently
/// unservable from memory, forcing every subsequent read through this
/// cache's mandatory disk-hit-then-live-conditional-revalidation path
/// even when nothing about the cached content had actually changed.
/// (Reproduced directly: `AssetCacheServiceRevalidationCoalescingTests`'s
/// `lastWaiterCancellingRevalidationLeavesPriorEntryUntouched`
/// hangs forever under the old comparison, since that live revalidation
/// is issued against a transport URL the test deliberately holds open —
/// exactly the network round trip this fix must prove is never
/// attempted at all once the sole outstanding newer authority is already
/// known to be abandoned.)
///
/// These three tests isolate the fix's exact decision boundary directly
/// against the actor's own internal issuance/retirement primitives
/// (accessible here only via `@testable import`), rather than through a
/// full `asset(for:)`/network round trip: the safety property this file
/// proves — a genuinely still-live newer authority must continue to
/// invalidate an older entry exactly as strictly as before — could not
/// otherwise be exercised without itself risking the exact same
/// held-transport hang this fix closes.
extension AssetCacheServiceTests {
    /// Named result for ``publishAndIssueNextAuthority(_:key:)`` — a plain
    /// tuple would exceed SwiftLint's `large_tuple` limit at three
    /// members.
    private struct ReservedAuthorityFixture {
        let cacheKey: AssetCacheKey
        let published: CachedAsset
        let reservedToken: AssetCacheService.CacheToken
    }

    /// Publishes a real entry for `key`, then durably issues one fresh
    /// ``AuthorityID`` for the same cache key (mirroring exactly what
    /// issuing a fresh, never-applied fetch/revalidation does) without
    /// ever marking it retiring — the baseline every test below starts
    /// from.
    private func publishAndIssueNextAuthority(
        _ layers: ServiceLayers,
        key: AssetKey
    ) async throws -> ReservedAuthorityFixture {
        let urls = candidateURLs(for: key)
        let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)
        await layers.transport.enqueue(.success(successResult(etag: "\"v1\"")), for: urls[0])
        let published = try await layers.service.asset(for: key)

        let preIssued = await layers.service.beginIssuance(for: cacheKey)
        var reservedToken = await layers.service.issueToken(for: cacheKey)
        reservedToken.durableClearEpoch = preIssued.clearEpoch
        reservedToken.diskAuthorityID = preIssued.diskAuthorityID
        return ReservedAuthorityFixture(
            cacheKey: cacheKey,
            published: published,
            reservedToken: reservedToken
        )
    }

    @Test(
        """
        A durably issued authority that is then marked retiring (e.g. its \
        sole waiter cancelled before the operation it belongs to ever applied \
        anything) must never poison an older, still-genuinely-current memory \
        entry: memoryEntryStillCurrent must walk past a gap of exclusively \
        confirmed-abandoned authorities rather than failing plain equality \
        against the most-recently-issued one
        """
    )
    func abandonedAuthorityGapDoesNotInvalidateStillCurrentMemoryEntry() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let layers = try makeService(directory: root, limits: limits)
            let fixture = try await publishAndIssueNextAuthority(layers, key: key)
            let cacheKey = fixture.cacheKey
            let published = fixture.published
            let reservedToken = fixture.reservedToken

            // The reservation above is never applied: it is immediately
            // retired, exactly as `cancelRevalidationWaiter`/`cancelWaiter`
            // do the instant a coalesced operation's last waiter leaves.
            await layers.service.markGenerationRetiring(reservedToken, for: cacheKey)

            let stillCurrent = await layers.service.memoryEntryStillCurrent(
                published.durableClearEpoch,
                storedAuthorityID: published.authorityID,
                for: cacheKey
            )
            #expect(
                stillCurrent,
                "A gap of exclusively abandoned authorities must never invalidate an older entry"
            )
        }
    }

    @Test(
        """
        A durably issued authority that is genuinely still pending (never \
        marked retiring, exactly as a real in-flight fetch/revalidation \
        that has not yet been cancelled or completed) must continue to \
        invalidate an older memory entry exactly as strictly as the \
        original plain-equality check did — proving the gap-tolerance fix \
        does not itself relax this authority model's safety property
        """
    )
    func pendingAuthorityGapStillInvalidatesMemoryEntry() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let layers = try makeService(directory: root, limits: limits)
            let fixture = try await publishAndIssueNextAuthority(layers, key: key)
            let cacheKey = fixture.cacheKey
            let published = fixture.published

            // Deliberately never marked retiring: this authority is still
            // genuinely (from this actor's own perspective) capable of
            // applying a different mutation for this key at any moment.
            let stillCurrent = await layers.service.memoryEntryStillCurrent(
                published.durableClearEpoch,
                storedAuthorityID: published.authorityID,
                for: cacheKey
            )
            #expect(
                !stillCurrent,
                "A still-pending newer authority must keep invalidating an older entry"
            )
        }
    }

    @Test(
        """
        A gap wider than AssetCacheService.maxRetiringGapWalk fails closed \
        even when every single authority inside it is confirmed retiring — \
        the defensive ceiling on this walk must actually engage rather \
        than silently performing an unbounded scan
        """
    )
    func retiringGapWiderThanBoundFailsClosed() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let layers = try makeService(directory: root, limits: limits)
            let urls = candidateURLs(for: key)
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            await layers.transport.enqueue(.success(successResult(etag: "\"v1\"")), for: urls[0])
            let published = try await layers.service.asset(for: key)

            // Issue and immediately retire one more authority than the
            // bound tolerates -- every single one of them individually
            // eligible to be walked past, but not all of them together.
            for _ in 0 ... AssetCacheService.maxRetiringGapWalk {
                let preIssued = await layers.service.beginIssuance(for: cacheKey)
                var token = await layers.service.issueToken(for: cacheKey)
                token.durableClearEpoch = preIssued.clearEpoch
                token.diskAuthorityID = preIssued.diskAuthorityID
                await layers.service.markGenerationRetiring(token, for: cacheKey)
            }

            let stillCurrent = await layers.service.memoryEntryStillCurrent(
                published.durableClearEpoch,
                storedAuthorityID: published.authorityID,
                for: cacheKey
            )
            #expect(
                !stillCurrent,
                "A gap wider than the defensive ceiling must fail closed, never scan unboundedly"
            )
        }
    }
}
