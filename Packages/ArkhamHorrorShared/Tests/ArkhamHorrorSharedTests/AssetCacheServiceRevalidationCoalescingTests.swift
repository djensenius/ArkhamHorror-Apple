@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Revalidation coalescing, out-of-order/stale-completion protection, and
/// waiter cancellation for ``AssetCacheService/revalidate(for:)``, split
/// out from `AssetCacheServiceRevalidationTests.swift` (which covers the
/// single-caller 304/404/validator-precondition behavior) purely to stay
/// under SwiftLint's `type_body_length`, the same way `AppModelTests` is
/// split by concern across sibling files.
///
/// Several tests below need a request that *starts* later to *complete*
/// before one that started earlier (to prove a delayed, now-stale
/// completion cannot resurrect or overwrite what a more authoritative one
/// already concluded). ``FakeAssetTransport``'s per-URL `hold`/`release` is
/// intentionally URL-scoped, not call-scoped, so it cannot express "hold
/// only the first of two calls to the same URL, then release only that
/// one" — the two calls would both be released together. Instead, these
/// tests use the transport's per-item `delayNanoseconds` (the first-issued
/// request's queued response is given a long artificial delay, the
/// second-issued request's a short one), which deterministically reorders
/// *completion* without touching *start* order or depending on ambient
/// task-scheduling.
extension AssetCacheServiceTests {
    /// `AssetCacheMetadata.etag` is deliberately `let` (see its own file):
    /// this rebuilds a ``CachedAsset`` with every field preserved except a
    /// substituted `etag`, standing in for "some other path updated the
    /// cached entry's validator" so a concurrently in-flight revalidation
    /// (captured under the *old* etag) is provably distinguishable from a
    /// caller that reads the cache afterward.
    func withSubstitutedETag(_ asset: CachedAsset, etag: String) -> CachedAsset {
        let metadata = asset.metadata
        return CachedAsset(
            payload: asset.payload,
            metadata: AssetCacheMetadata(
                cacheKeyHex: metadata.cacheKeyHex,
                contentType: metadata.contentType,
                encodedByteCount: metadata.encodedByteCount,
                width: metadata.width,
                height: metadata.height,
                payloadSHA256Hex: metadata.payloadSHA256Hex,
                etag: etag,
                lastModified: metadata.lastModified,
                resolvedURLString: metadata.resolvedURLString,
                insertedAt: metadata.insertedAt,
                lastAccessedAt: metadata.lastAccessedAt
            )
        )
    }

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
            // Both calls have now started; give the (deliberately
            // non-deterministic) second registration a moment to land
            // before releasing, so both are provably waiting on the same
            // shared fetch rather than one having already raced ahead.
            try await Task.sleep(nanoseconds: 20_000_000)
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

            // The first-issued (etag "v1") request's response is a slow,
            // stale 304; the second-issued (etag "v2") request's response
            // is a fast, definitive 404. Enqueue order matches call order
            // (FIFO per URL), so the slow entry is consumed by whichever
            // call starts first.
            await transport.enqueue(
                .success(.notModified),
                for: urls[0],
                delayNanoseconds: 300_000_000
            )
            await transport.enqueue(.success(.notFound), for: urls[0])

            let taskA = Task { try await service.revalidate(for: key) }
            // Wait until op A's own network call has actually started
            // (call 2, after the initial fetch's call 1) before mutating
            // the cache out from under it — this is what makes op B's
            // subsequent call see a different validator snapshot and
            // start its own independent operation instead of joining A's.
            await transport.waitForCallCount(2, for: urls[0])

            let bumped = withSubstitutedETag(initial, etag: "\"v2\"")
            await memoryCache.set(cacheKey, asset: bumped)

            let taskB = Task { try await service.revalidate(for: key) }
            await #expect(throws: AssetError.candidatesExhausted) {
                _ = try await taskB.value
            }

            await #expect(throws: AssetError.staleConditionalResponse) {
                _ = try await taskA.value
            }

            // Op A's stale 304 must not have resurrected anything: the
            // entry op B's 404 evicted stays evicted in both layers.
            let memoryAfter = await memoryCache.get(cacheKey)
            #expect(memoryAfter == nil)
            let diskAfter = await diskCache.get(cacheKey)
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
            let initial = try await service.asset(for: key)

            let oldBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            let newBody = AssetImageFixtureBuilder.validAVIF(width: 8, height: 8)
            // Op A (etag "v1", started first) gets a slow but otherwise
            // perfectly valid fresh response; op B (etag "v2", started
            // second) gets a fast valid fresh response with different
            // (distinguishable) bytes.
            await transport.enqueue(
                .success(successResult(body: oldBody, etag: "\"v1-refreshed\"")),
                for: urls[0],
                delayNanoseconds: 300_000_000
            )
            await transport.enqueue(
                .success(successResult(body: newBody, etag: "\"v2-refreshed\"")),
                for: urls[0]
            )

            let taskA = Task { try await service.revalidate(for: key) }
            await transport.waitForCallCount(2, for: urls[0])

            let bumped = withSubstitutedETag(initial, etag: "\"v2\"")
            await memoryCache.set(cacheKey, asset: bumped)

            let taskB = Task { try await service.revalidate(for: key) }
            let resultB = try await taskB.value
            #expect(resultB.payload == newBody)

            await #expect(throws: AssetError.staleConditionalResponse) {
                _ = try await taskA.value
            }

            // Op A's stale (but individually valid) response must not have
            // overwritten op B's newer, already-published result.
            let memoryAfter = await memoryCache.get(cacheKey)
            #expect(memoryAfter?.payload == newBody)
            let diskAfter = await diskCache.get(cacheKey)
            #expect(diskAfter?.payload == newBody)
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
