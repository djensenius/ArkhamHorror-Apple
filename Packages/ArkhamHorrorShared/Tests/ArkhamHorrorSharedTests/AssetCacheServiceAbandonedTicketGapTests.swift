@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic, white-box coverage for
/// ``AssetCacheService/memoryEntryStillCurrent(_:storedGeneration:for:)``'s
/// own gap-tolerance logic (`ticketGapIsEntirelyAbandoned(from:downTo:for:)`)
/// — a fix for a genuine hang this subsystem's own cancellation
/// contract otherwise produces: reserving a fresh durable ticket for a
/// key (``AssetCacheService/beginIssuance(for:)``/
/// ``AssetCacheService/beginRevalidationIssuance``)
/// -- happens the instant a fresh fetch/revalidation is *issued* —
/// strictly before it is known whether that operation will ever
/// complete. A prior revision of ``memoryEntryStillCurrent(_:storedGeneration:for:)``
/// compared a stored entry's own ``AssetMemoryCache/CachedAsset/writeGeneration``
/// against `key`'s current durable *highest issued* ticket using plain
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
/// attempted at all once the sole outstanding newer ticket is already
/// known to be abandoned.)
///
/// These three tests isolate the fix's exact decision boundary directly
/// against the actor's own internal issuance/retirement primitives
/// (accessible here only via `@testable import`), rather than through a
/// full `asset(for:)`/network round trip: the safety property this file
/// proves — a genuinely still-live newer ticket must continue to
/// invalidate an older entry exactly as strictly as before — could not
/// otherwise be exercised without itself risking the exact same
/// held-transport hang this fix closes.
extension AssetCacheServiceTests {
    /// Named result for ``publishAndReserveNextTicket(_:key:)`` — a plain
    /// tuple would exceed SwiftLint's `large_tuple` limit at three
    /// members.
    private struct ReservedTicketFixture {
        let cacheKey: AssetCacheKey
        let published: CachedAsset
        let reservedTicket: AssetCacheService.CacheToken
    }

    /// Publishes a real entry for `key`, then durably reserves one fresh
    /// ticket for the same cache key (mirroring exactly what issuing a
    /// fresh, never-applied fetch/revalidation does) without ever
    /// marking it retiring — the baseline every test below starts from.
    private func publishAndReserveNextTicket(
        _ layers: ServiceLayers,
        key: AssetKey
    ) async throws -> ReservedTicketFixture {
        let urls = candidateURLs(for: key)
        let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
        let cacheKey = AssetCacheKey(for: key, candidates: candidates)
        await layers.transport.enqueue(.success(successResult(etag: "\"v1\"")), for: urls[0])
        let published = try await layers.service.asset(for: key)

        let preIssued = await layers.service.beginIssuance(for: cacheKey)
        var reservedTicket = await layers.service.issueToken(for: cacheKey)
        reservedTicket.durableClearEpoch = preIssued.clearEpoch
        reservedTicket.diskWriteGeneration = preIssued.diskWriteGeneration
        return ReservedTicketFixture(
            cacheKey: cacheKey,
            published: published,
            reservedTicket: reservedTicket
        )
    }

    @Test(
        """
        A durably reserved ticket that is then marked retiring (e.g. its \
        sole waiter cancelled before the operation it belongs to ever applied \
        anything) must never poison an older, still-genuinely-current memory \
        entry: memoryEntryStillCurrent must walk past a gap of exclusively \
        confirmed-abandoned tickets rather than failing plain equality \
        against the highest issued one
        """
    )
    func abandonedTicketGapDoesNotInvalidateStillCurrentMemoryEntry() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let layers = try makeService(directory: root, limits: limits)
            let fixture = try await publishAndReserveNextTicket(layers, key: key)
            let cacheKey = fixture.cacheKey
            let published = fixture.published
            let reservedTicket = fixture.reservedTicket

            // The reservation above is never applied: it is immediately
            // retired, exactly as `cancelRevalidationWaiter`/`cancelWaiter`
            // do the instant a coalesced operation's last waiter leaves.
            await layers.service.markGenerationRetiring(reservedTicket, for: cacheKey)

            let stillCurrent = await layers.service.memoryEntryStillCurrent(
                published.durableClearEpoch,
                storedGeneration: published.writeGeneration,
                for: cacheKey
            )
            #expect(
                stillCurrent,
                "A gap of exclusively abandoned tickets must never invalidate an older entry"
            )
        }
    }

    @Test(
        """
        A durably reserved ticket that is genuinely still pending (never \
        marked retiring, exactly as a real in-flight fetch/revalidation \
        that has not yet been cancelled or completed) must continue to \
        invalidate an older memory entry exactly as strictly as the \
        original plain-equality check did — proving the gap-tolerance fix \
        does not itself relax this authority model's safety property
        """
    )
    func pendingTicketGapStillInvalidatesMemoryEntry() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let layers = try makeService(directory: root, limits: limits)
            let fixture = try await publishAndReserveNextTicket(layers, key: key)
            let cacheKey = fixture.cacheKey
            let published = fixture.published

            // Deliberately never marked retiring: this ticket is still
            // genuinely (from this actor's own perspective) capable of
            // applying a different mutation for this key at any moment.
            let stillCurrent = await layers.service.memoryEntryStillCurrent(
                published.durableClearEpoch,
                storedGeneration: published.writeGeneration,
                for: cacheKey
            )
            #expect(
                !stillCurrent,
                "A genuinely still-pending newer ticket must continue to invalidate an older entry"
            )
        }
    }

    @Test(
        """
        A gap wider than AssetCacheService.maxRetiringGapWalk fails closed \
        even when every single ticket inside it is confirmed retiring — \
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

            // Reserve and immediately retire one more ticket than the
            // bound tolerates -- every single one of them individually
            // eligible to be walked past, but not all of them together.
            for _ in 0 ... AssetCacheService.maxRetiringGapWalk {
                let preIssued = await layers.service.beginIssuance(for: cacheKey)
                var ticket = await layers.service.issueToken(for: cacheKey)
                ticket.durableClearEpoch = preIssued.clearEpoch
                ticket.diskWriteGeneration = preIssued.diskWriteGeneration
                await layers.service.markGenerationRetiring(ticket, for: cacheKey)
            }

            let stillCurrent = await layers.service.memoryEntryStillCurrent(
                published.durableClearEpoch,
                storedGeneration: published.writeGeneration,
                for: cacheKey
            )
            #expect(
                !stillCurrent,
                "A gap wider than the defensive ceiling must fail closed, never scan unboundedly"
            )
        }
    }
}
