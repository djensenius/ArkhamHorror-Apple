@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Two of ``CrossServiceAuthorityTests``'s own tests, split into this
/// sibling extension file purely to keep that struct's own
/// `type_body_length` under this package's limit. Shares every helper
/// defined in `CrossServiceAuthorityTests.swift` itself.
extension CrossServiceAuthorityTests {
    @Test(
        """
        A second, concurrent disk-only caller joining an already in-flight conditional \
        revalidation must reserve no durable disk authority of its own: the first caller's \
        held request must still be able to publish its own result once released, never wrongly \
        rejected as stale by a wasted reservation the second caller's own join made
        """
    )
    func joiningDiskOnlyCallerReservesNoDurableAuthority() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let (seedService, seedTransport) = try makeIndependentService(
                directory: directory,
                limits: limits
            )
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)

            // Seeds the shared disk directory with an entry that *does*
            // carry a validator, so a later disk-only hit can attempt a
            // genuine conditional revalidation rather than an
            // unconditional re-fetch.
            await seedTransport.enqueue(
                .success(successResult(etag: "\"v1\"")),
                for: urls[0]
            )
            let seeded = try await seedService.asset(for: key)
            #expect(seeded.metadata.etag == "\"v1\"")

            // A fresh service, sharing no in-memory state with
            // `seedService` at all, so both concurrent lookups below
            // start from a genuine disk-only hit.
            let (service, transport) = try makeIndependentService(
                directory: directory,
                limits: limits
            )
            await transport.hold(urls[0])
            await transport.enqueue(.success(.notModified), for: urls[0])

            let firstTask = Task<CachedAsset, Error> {
                try await service.asset(for: key)
            }
            // Waits until the first caller's own conditional network
            // call has actually started (registering it as the in-flight
            // revalidation the second caller below must join) before
            // starting the second.
            await transport.waitForCallCount(1, for: urls[0])

            let secondTask = Task<CachedAsset, Error> {
                try await service.asset(for: key)
            }
            // Waits until the second caller has genuinely joined the
            // same in-flight revalidation as a waiter, rather than
            // assuming a fixed delay is long enough.
            try await waitForRevalidationWaiterCount(2, cacheKey: cacheKey, on: service)

            // Exactly one network call must ever have been made: a
            // genuinely joining second caller reserves and issues
            // nothing of its own, so there is no second request to make.
            #expect(await transport.callCount(for: urls[0]) == 1)

            await transport.release(urls[0])

            // Neither waiter may observe `AssetError.staleOperation`: a
            // prior revision's eager reservation, made by the *second*
            // caller purely on the chance it might need one before ever
            // knowing it would join, durably bumped the shared per-key
            // issuance counter past the first caller's own already-issued
            // ticket -- stranding the first caller's own legitimate,
            // already in-flight publish/touch the instant it tried to
            // land, and failing both waiters of what should have been a
            // single successful, genuinely coalesced operation.
            let firstResult = try await firstTask.value
            let secondResult = try await secondTask.value
            #expect(firstResult.payload == seeded.payload)
            #expect(secondResult.payload == seeded.payload)
            #expect(await transport.callCount(for: urls[0]) == 1)
        }
    }

    @Test(
        """
        A sibling service's fresh issuance for the same key -- reserved the instant its own \
        fetch begins, strictly before that fetch's network round trip or publish ever lands -- \
        must immediately untrust another service's already-cached memory entry, even though no \
        mutation has actually applied yet: exact equality against the highest durably issued \
        ticket, not merely `>=` against the highest applied one, is what catches this
        """
    )
    func siblingIssuanceAloneInvalidatesMemoryEntryBeforeItApplies() async throws {
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
            let payloadB = AssetImageFixtureBuilder.validAVIF(width: 9, height: 9)

            // A fully publishes and caches in its own memory -- no
            // validator at all, so its own entry can never be
            // conditionally revalidated later, only ever trusted as an
            // ordinary memory hit or re-fetched outright.
            await transportA.enqueue(.success(successResult(body: payloadA)), for: urls[0])
            let firstFetch = try await serviceA.asset(for: key)
            #expect(firstFetch.payload == payloadA)
            #expect(await transportA.callCount(for: urls[0]) == 1)

            // B begins a brand-new (never coalesced with A -- a separate
            // service instance shares no in-process coalescing state at
            // all) fetch for the exact same key, and its own network
            // response is held indefinitely: B's disk-durable issuance
            // ticket for this key has therefore already been reserved
            // (``AssetDiskCache/beginIssuance(for:)`` durably bumps the
            // issuance counter as the very first step of a fresh fetch,
            // strictly before any network I/O), but nothing has been --
            // or, for the rest of this test, ever will be -- applied.
            await transportB.hold(urls[0])
            await transportB.enqueue(.success(successResult(body: payloadB)), for: urls[0])
            let heldTaskB = Task<CachedAsset, Error> { try await serviceB.asset(for: key) }
            await transportB.waitForCallCount(1, for: urls[0])

            // A's own next lookup for this exact key must not trust its
            // own still-untouched, already-cached memory entry: B's
            // fresh ticket is already the current highest *issued* one
            // for this key, even though B's own mutation has not (and,
            // in this test, never will) actually apply. A prior revision
            // compared only against the highest *applied* ticket and
            // would have kept trusting `payloadA` here indefinitely,
            // right up until B's held response eventually resolved --
            // an unbounded staleness window with no relationship at all
            // to when B's own operation was actually issued.
            let payloadC = AssetImageFixtureBuilder.validAVIF(width: 12, height: 12)
            await transportA.enqueue(.success(successResult(body: payloadC)), for: urls[0])
            let secondFetch = try await serviceA.asset(for: key)
            #expect(
                secondFetch.payload != payloadA,
                """
                A must never keep serving its own memory entry once a sibling's fresher ticket \
                has been issued for this key, whether or not that sibling has applied anything \
                yet
                """
            )
            #expect(secondFetch.payload == payloadC)
            #expect(
                await transportA.callCount(for: urls[0]) == 2,
                """
                A's second lookup must be a genuine new network fetch, not a trusted memory hit \
                that only a torn or applied-ticket-only read would have permitted
                """
            )

            // Cleanup: release B's held response so its own task does not
            // leak past this test's scope. B's own eventual publish
            // attempt is expected to be rejected as stale by the durable
            // per-key CAS (A's own later-issued ticket, from its second
            // fetch above, has since become the current highest issued
            // one) -- irrelevant to what this test itself is proving,
            // but asserted anyway so a future regression in that
            // rejection path would be caught here too, not silently
            // ignored by an unawaited task.
            await transportB.release(urls[0])
            await #expect(throws: AssetError.staleOperation) {
                try await heldTaskB.value
            }
        }
    }
}
