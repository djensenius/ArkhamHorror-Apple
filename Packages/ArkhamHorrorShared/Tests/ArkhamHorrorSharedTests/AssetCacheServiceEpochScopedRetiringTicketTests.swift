@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of a regression exposed while wiring
/// ``AssetCacheService/authorityIsRetiring(_:epoch:for:)`` into the
/// final waiter-delivery authority decision
/// (`AssetCacheService+WaiterAcknowledgement.swift`'s
/// `isTokenAuthoritative(_:for:currentAuthority:)`): a bare `Int` ticket,
/// with no durable-clear-epoch dimension, cannot distinguish two
/// completely unrelated mutations that happen to share the same numeric
/// issuance ticket on either side of a whole-cache clear.
///
/// ``AssetDiskCache/removeAll()`` sweeps away every key's own merged
/// authority record (`AssetDiskCache+Disposition.swift`'s
/// `KeyAuthorityRecord`), so the very next fresh issuance for that same
/// key legitimately starts back at ticket `1` -- under a strictly newer
/// durable clear epoch. Before this fix, ``AssetCacheService/retiringGenerations``
/// tracked only `key -> Set<Int>` (a bare ticket number), so a ticket `1`
/// abandoned (cancelled with no surviving waiter) *before* a clear could
/// wrongly poison a completely legitimate, freshly-issued ticket `1`
/// *after* that same clear -- even though the two have nothing to do with
/// each other. This test proves the fix
/// (``AssetCacheService/RetiringAuthority``, pairing the ticket with the
/// epoch it was retracted under) by reproducing the exact sequence that
/// previously failed deterministically: abandon ticket 1 under epoch 0,
/// force a whole-cache clear (bumping to epoch 1 and resetting this key's
/// own issuance counter), then prove a brand new ticket 1 issued under
/// epoch 1 is fully servable and is never mistaken for the old, unrelated
/// abandoned one.
extension AssetCacheServiceTests {
    @Test(
        """
        A ticket abandoned (cancelled with no surviving waiter) under one durable clear epoch \
        must never poison a numerically-identical ticket legitimately reissued for the same \
        key under a later epoch, once a whole-cache clear has reset that key's own issuance \
        counter
        """
    )
    func abandonedTicketUnderOldEpochDoesNotPoisonSameTicketNumberUnderNewEpoch() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)

            // Abandon ticket 1 under epoch 0: the sole waiter is
            // cancelled at the exact instant the fetch completes (see
            // `AssetCacheServiceWaiterAcknowledgementTests.swift`'s
            // identical hook usage), so `retractUndeliveredMutation`
            // durably marks that ticket retiring for this key -- but
            // strictly under epoch 0, never any later one.
            await transport.hold(urls[0])
            await transport.enqueue(.success(successResult()), for: urls[0])
            let abandonedTask = Task { try await service.asset(for: key) }
            await transport.waitForCallCount(1, for: urls[0])
            try await waitForInFlightWaiterCount(1, for: key, on: service)
            await service.installTestOnlyBeforeFetchResumesWaiters {
                abandonedTask.cancel()
            }
            await transport.release(urls[0])
            let abandonedResult = await abandonedTask.result
            #expect(throws: (any Error).self) { try abandonedResult.get() }

            // A whole-cache clear: bumps the durable clear epoch to 1
            // and sweeps this key's own merged authority record away,
            // so the very next issuance for this key legitimately starts
            // back at ticket 1 -- under epoch 1, never epoch 0.
            try await service.evictAll()

            // A fresh, entirely unrelated fetch for the *same* key,
            // post-clear: this reissues ticket 1, but now under epoch 1.
            // Before the fix, `authorityIsRetiring` compared only
            // the bare ticket number and would have found ticket 1 in
            // the (epoch-unscoped) retiring set left behind by the
            // abandoned pre-clear operation above, wrongly rejecting
            // this brand new, entirely legitimate mutation as though it
            // were the old abandoned one.
            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 7, height: 7)
            await transport.enqueue(.success(successResult(body: freshBody)), for: urls[0])
            let fresh = try await service.asset(for: key)
            #expect(fresh.payload == freshBody)

            // Must also be trustworthy on a second, immediate lookup --
            // i.e. actually durably published and servable from memory,
            // not merely returned once by the fetch call itself.
            let servedAgain = try await service.asset(for: key)
            #expect(servedAgain.payload == freshBody)
            let callCount = await transport.callCount(for: urls[0])
            #expect(
                callCount == 2,
                "Expected the abandoned pre-clear fetch + the one fresh post-clear fetch only"
            )
        }
    }
}
