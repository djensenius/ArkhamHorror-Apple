@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Revalidation coalescing, out-of-order/stale-completion protection, and
/// waiter cancellation for ``AssetCacheService/revalidate(for:)``, split
/// out from `AssetCacheServiceRevalidationTests.swift` (which covers the
/// single-caller 304/404/validator-precondition behavior) purely to stay
/// under SwiftLint's `type_body_length`, the same way `AppModelTests` is
/// split by concern across sibling files.
/// Several tests below need a request that *starts* later to *complete*
/// before one that started earlier (to prove a delayed, now-stale
/// completion cannot resurrect or overwrite what a more authoritative one
/// already concluded). ``FakeAssetTransport``'s per-URL `hold`/`release` is
/// intentionally URL-scoped, not call-scoped, so it cannot express "hold
/// only the first of two calls to the same URL, then release only that
/// one" — both calls would be released together. Instead, these tests use
/// the transport's per-item `delayNanoseconds` (the first-issued request's
/// queued response is given a long artificial delay, the second-issued
/// request's a short one), which deterministically reorders *completion*
/// without touching *start* order or depending on ambient task-scheduling.
///
/// Three of these tests construct op B as a fresh, independent fetch that
/// only starts *after* an explicit `invalidate(_:)` for the same key, not
/// as a second, differently-validated `revalidate(for:)` call for the
/// still-cached entry: `beginRevalidationIssuance`'s own gate requires the
/// caller's historical write generation to match the *durably applied*
/// ticket for that key, so two independently issued, still-unapplied
/// revalidations against the same underlying entry can never coexist
/// within one service instance — the second one always either fails its
/// own memory-hit check and joins the first's in-flight slot (both
/// observe the same, still-unpublished disk state), or is rejected
/// outright by the issuance gate. That is the service's own coalescing
/// invariant working as intended (see
/// `revalidationCoalescesConcurrentIdenticalRequests` below), not a gap
/// for these tests to defeat by forging cache state no real caller could
/// ever produce. A genuinely independent *sibling service/process* racing
/// the same key is instead covered by `CrossServiceAuthorityTests.swift`.
extension AssetCacheServiceTests {
    @Test(
        "Two concurrent identical revalidate(for:) calls are coalesced onto a single network fetch"
    )
    func revalidationCoalescesConcurrentIdenticalRequests() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(successResult(etag: "\"v1\"")), for: urls[0])
            let initial = try await service.asset(for: key)
            #expect(initial.metadata.etag == "\"v1\"")

            await transport.hold(urls[0])
            await transport.enqueue(.success(.notModified), for: urls[0])

            async let first = service.revalidate(for: key)
            async let second = service.revalidate(for: key)
            // Coalescing means only ONE network call is ever made for
            // both callers: the initial fetch (1) plus this single shared
            // revalidation fetch (2) — never a third.
            await transport.waitForCallCount(2, for: urls[0])
            // Waits for both callers to have genuinely registered as
            // waiters on the same shared revalidation, rather than a
            // fixed `Task.sleep` guess -- real internal state, immune to
            // scheduler jitter under load.
            try await waitForInFlightRevalidationWaiterCount(2, for: key, on: service)
            await transport.release(urls[0])

            let (firstResult, secondResult) = try await (first, second)
            #expect(firstResult.payload == secondResult.payload)
            // Exactly one revalidation network call, despite two callers:
            // the initial fetch (1) plus a single shared revalidation
            // fetch (2) — never a third.
            let callCount = await transport.callCount(for: urls[0])
            #expect(callCount == 2)
        }
    }

    @Test(
        """
        A delayed, now-stale 304 cannot resurrect a cache entry a definitive 404 already \
        evicted, even though the 304's request started first
        """
    )
    func delayedStale304CannotResurrectAfterADefinitiveNotFound() async throws {
        try await withScratchDirectory { directory in
            let layers = try makeService(directory: directory, limits: standardLimits())
            let memoryCache = layers.memoryCache
            let diskCache = layers.diskCache
            let transport = layers.transport
            let service = layers.service

            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let cacheKey = AssetCacheKey(
                for: key,
                candidates: AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            )
            await transport.enqueue(.success(successResult(etag: "\"v1\"")), for: urls[0])
            let initial = try await service.asset(for: key)
            #expect(initial.metadata.etag == "\"v1\"")

            // Op A's conditional revalidation (against etag "v1") issues
            // its ticket and starts its network call first, but is given
            // a slow, stale 304. While it is still in flight -- its
            // ticket already captured, its network round trip already
            // under way, but no response yet examined -- a legitimate,
            // independent per-key invalidation runs to completion for
            // this exact key (standing in for whatever other concurrent
            // event durably established a newer per-key authority in
            // production: a distinct in-flight write, a definitive 404 on
            // a sibling fetch, or an explicit administrative
            // invalidation; see this file's own header comment for why
            // op B is constructed this way, as a fresh independent fetch,
            // rather than a forged second `revalidate(for:)` call). Op B
            // is then a fresh, fully independent fetch attempt for the
            // now-empty key, which gets a definitive 404.
            await transport.enqueue(
                .success(.notModified),
                for: urls[0],
                delayNanoseconds: 300_000_000
            )

            let taskA = Task { try await service.revalidate(for: key) }
            await transport.waitForCallCount(2, for: urls[0])

            await service.invalidate(cacheKey)

            // Unlike `revalidate(for:)` (which conditions against a
            // single already-resolved URL), a fresh `asset(for:)` fetch
            // walks the *whole* candidate list, so every candidate must
            // return a definitive 404 for it to converge on
            // `candidatesExhausted` rather than an empty-queue error from
            // the fake transport.
            for url in urls {
                await transport.enqueue(.success(.notFound), for: url)
            }
            let taskB = Task { try await service.asset(for: key) }
            await #expect(throws: AssetError.candidatesExhausted) {
                _ = try await taskB.value
            }

            await #expect(throws: AssetError.staleOperation) {
                _ = try await taskA.value
            }

            // Op A's stale 304 must not have resurrected anything: the
            // entry the invalidation (and op B's confirming 404) evicted
            // stays evicted in both layers.
            let memoryAfter = await memoryCache.get(cacheKey)
            #expect(memoryAfter == nil)
            let diskAfter = try await diskCache.get(cacheKey)
            #expect(diskAfter == nil)
        }
    }

    @Test(
        """
        A delayed, now-stale successful revalidation cannot overwrite a cache entry a newer, \
        already-published revalidation produced, even though it started first
        """
    )
    func oldDelayed200CannotOverwriteANewer200() async throws {
        try await withScratchDirectory { directory in
            let layers = try makeService(directory: directory, limits: standardLimits())
            let memoryCache = layers.memoryCache
            let diskCache = layers.diskCache
            let transport = layers.transport
            let service = layers.service

            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let cacheKey = AssetCacheKey(
                for: key,
                candidates: AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            )
            await transport.enqueue(.success(successResult(etag: "\"v1\"")), for: urls[0])
            _ = try await service.asset(for: key)

            let oldBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            let newBody = AssetImageFixtureBuilder.validAVIF(width: 8, height: 8)
            // Op A's conditional revalidation (against etag "v1") issues
            // its ticket and starts its network call first, but is given
            // a slow, otherwise perfectly valid fresh response. While it
            // is still in flight, a legitimate, independent per-key
            // invalidation runs to completion for this exact key (see
            // `delayedStale304CannotResurrectAfterADefinitiveNotFound`'s
            // own comment above for why op B must be constructed this
            // way rather than as a forged second `revalidate(for:)`
            // call), and op B is a fresh, fully independent fetch that
            // gets a fast valid response with different, distinguishable
            // bytes.
            await transport.enqueue(
                .success(successResult(body: oldBody, etag: "\"v1-refreshed\"")),
                for: urls[0],
                delayNanoseconds: 300_000_000
            )

            let taskA = Task { try await service.revalidate(for: key) }
            await transport.waitForCallCount(2, for: urls[0])

            await service.invalidate(cacheKey)

            await transport.enqueue(
                .success(successResult(body: newBody, etag: "\"v2-refreshed\"")),
                for: urls[0]
            )
            let taskB = Task { try await service.asset(for: key) }
            let resultB = try await taskB.value
            #expect(resultB.payload == newBody)

            await #expect(throws: AssetError.staleOperation) {
                _ = try await taskA.value
            }

            // Op A's stale (but individually valid) response must not have
            // overwritten op B's newer, already-published result.
            let memoryAfter = await memoryCache.get(cacheKey)
            #expect(memoryAfter?.payload == newBody)
            let diskAfter = try await diskCache.get(cacheKey)
            #expect(diskAfter?.payload == newBody)
        }
    }

    @Test(
        """
        An older-issued revalidation that completes and would-be-publish \
        *before* a newer-issued one (still in flight) does not win: \
        authority is fixed by issuance order, not completion order, so the \
        newer-issued operation remains sole publish authority even though \
        it finishes later
        """
    )
    func olderIssuedFastCompletionCannotOutrankNewerIssuedStillInFlight() async throws {
        try await withScratchDirectory { directory in
            let layers = try makeService(directory: directory, limits: standardLimits())
            let memoryCache = layers.memoryCache
            let diskCache = layers.diskCache
            let transport = layers.transport
            let service = layers.service

            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let cacheKey = AssetCacheKey(
                for: key,
                candidates: AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            )
            await transport.enqueue(.success(successResult(etag: "\"v1\"")), for: urls[0])
            _ = try await service.asset(for: key)

            let olderBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            let newerBody = AssetImageFixtureBuilder.validAVIF(width: 8, height: 8)
            // Op A's conditional revalidation (issued first, against etag
            // "v1") gets only a short delay, so it is the one whose
            // network round trip resolves and reaches its own final
            // authority check *first* -- but by then a legitimate,
            // independent per-key invalidation has already run to
            // completion (see
            // `delayedStale304CannotResurrectAfterADefinitiveNotFound`'s
            // comment above for why op B must be a fresh, independent
            // fetch rather than a forged second `revalidate(for:)` call),
            // and op B -- issued *after* A, while A's short delay is
            // still pending -- is given a much longer delay, so it is
            // still genuinely in flight (its own network call already
            // started, confirmed below) at the exact moment op A's fast
            // completion is rejected. This is the *inverse* of
            // ``oldDelayed200CannotOverwriteANewer200`` above: here the
            // *older*-issued operation is the one whose network response
            // comes back first, and it must still lose -- not because it
            // finished late, but because a newer per-key authority was
            // already established before its own completion was ever
            // checked, regardless of what op B's own network round trip
            // has or has not done yet.
            await transport.enqueue(
                .success(successResult(body: olderBody, etag: "\"v1-refreshed\"")),
                for: urls[0],
                delayNanoseconds: 20_000_000
            )

            let taskA = Task { try await service.revalidate(for: key) }
            await transport.waitForCallCount(2, for: urls[0])

            await service.invalidate(cacheKey)

            await transport.enqueue(
                .success(successResult(body: newerBody, etag: "\"v2-refreshed\"")),
                for: urls[0],
                delayNanoseconds: 300_000_000
            )
            let taskB = Task { try await service.asset(for: key) }
            // Confirms op B's own network call has genuinely started --
            // it is "still in flight", not merely about to be issued --
            // before asserting op A's own (much sooner) completion is
            // rejected.
            await transport.waitForCallCount(3, for: urls[0])

            await #expect(throws: AssetError.staleOperation) {
                _ = try await taskA.value
            }
            let resultB = try await taskB.value
            #expect(resultB.payload == newerBody)

            // Op A's fast-but-older response must never have been
            // published at all -- not even transiently -- and op B's
            // slower-but-newer response is what both cache layers hold.
            let memoryAfter = await memoryCache.get(cacheKey)
            #expect(memoryAfter?.payload == newerBody)
            let diskAfter = try await diskCache.get(cacheKey)
            #expect(diskAfter?.payload == newerBody)
        }
    }

    @Test(
        """
        Cancelling the sole waiter of a revalidation stops the fetch and leaves the previously \
        cached entry untouched; a subsequent revalidate(for:) starts entirely fresh work
        """
    )
    func lastWaiterCancellingRevalidationLeavesPriorEntryUntouched() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(successResult(etag: "\"v1\"")), for: urls[0])
            let initial = try await service.asset(for: key)

            await transport.hold(urls[0])
            await transport.enqueue(.success(successResult(etag: "\"v2\"")), for: urls[0])

            let taskA = Task { try await service.revalidate(for: key) }
            await transport.waitForCallCount(2, for: urls[0])
            taskA.cancel()

            await #expect(throws: CancellationError.self) {
                _ = try await taskA.value
            }

            let asset = try await service.asset(for: key)
            #expect(asset.payload == initial.payload)
            #expect(
                asset.metadata.etag == "\"v1\"",
                "The cancelled revalidation's v2 response must never have been published"
            )

            // The cancelled attempt was stopped (via the held transport's
            // cooperative cancellation) before it ever reached the point
            // of consuming its queued "v2" response — proven by that
            // response now being the *next* item a fresh call actually
            // receives, rather than a distinct freshly enqueued one, since
            // nothing else could have consumed it in between.
            await transport.release(urls[0])
            let revalidated = try await service.revalidate(for: key)
            #expect(
                revalidated.metadata.etag == "\"v2\"",
                """
                A fresh revalidation must start entirely new work (its own transport call) \
                rather than attempting to join the already-cancelled and removed prior entry
                """
            )
        }
    }
}
