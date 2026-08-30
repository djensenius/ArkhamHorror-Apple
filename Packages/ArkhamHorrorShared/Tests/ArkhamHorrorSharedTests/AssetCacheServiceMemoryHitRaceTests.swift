@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of the exact race the 14th cumulative
/// review's finding #2 requires closed at the
/// ``AssetCacheService`` memory-hit boundary, for both
/// ``AssetCacheService/asset(for:)`` and
/// ``AssetCacheService/revalidate(for:)`` (companion to
/// `AssetCacheServiceDiskReadRaceTests.swift`, which closes the analogous
/// disk-hit race for both entry points): a memory-cache hit that was
/// already captured *before* a concurrent, more-authoritative
/// invalidation (a direct `invalidate()` or a cache-wide `evictAll()`)
/// completed must never be returned, or handed to
/// `revalidateExisting(...)` (which unconditionally mints a *fresh*
/// authoritative token from whatever bytes it is given), once that
/// invalidation has completed — even though the memory-cache read itself
/// encountered no error and returned a structurally valid, still-decoded
/// entry.
///
/// Split from `AssetCacheServiceTests.swift` purely for `file_length`,
/// reusing its `withService`/`cardArtKey`/`candidateURLs`/`successResult`
/// helpers.
extension AssetCacheServiceTests {
    /// A minimal rendezvous, identical in shape to
    /// `AssetCacheServiceDiskReadRaceTests.swift`'s private `PauseGate`
    /// (not shared across files: each race test file's pause gate is
    /// deliberately self-contained, the same way each is free to phrase
    /// its own doc comments around the specific race it closes).
    private actor PauseGate {
        private var hasStarted = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var isReleased = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func waitUntilStarted() async {
            if hasStarted {
                return
            }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func markStartedAndWaitForRelease() async {
            hasStarted = true
            let waiters = startWaiters
            startWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
            if isReleased {
                return
            }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func release() {
            isReleased = true
            let waiters = releaseWaiters
            releaseWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    @Test(
        """
        A memory-cache hit already captured by revalidate(for:) is never used to mint a fresh \
        authoritative revalidation once a concurrent invalidate() completes while that read was \
        still paused
        """
    )
    func racedMemoryHitAgainstInvalidateIsNeverResurrected() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(successResult(etag: "\"v1\"")), for: urls[0])
            let seeded = try await service.asset(for: key)
            #expect(seeded.metadata.etag == "\"v1\"")

            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)

            let gate = PauseGate()
            await service.memoryCache.installTestOnlyPauseBeforeReturningHit {
                await gate.markStartedAndWaitForRelease()
            }

            let revalidateTask = Task { try await service.revalidate(for: key) }
            await gate.waitUntilStarted()

            // While the paused `revalidate(for:)` call still only holds
            // the `"v1"`-etag entry it already captured from memory, run
            // a direct, unconditional invalidation for this exact key to
            // completion — standing in for whatever more-authoritative
            // concurrent event (a definitive 404 on a distinct in-flight
            // fetch, or a cache-wide `evictAll()`) actually cleared it in
            // production. The memory *and* disk entries are both gone by
            // the time this returns.
            await service.invalidate(cacheKey)

            // Only once the invalidation has fully completed does the
            // test let the paused read actually resume and return its
            // already-captured (now-stale) hit, so the interleaving this
            // asserts is unambiguous rather than a race against
            // `invalidate()`'s own completion.
            await gate.release()

            // Nothing is left to condition a revalidation against: the
            // disk-hit branch below the (rejected) memory-hit branch must
            // also find no current entry, so this must throw the same
            // typed "nothing to revalidate" error a clean, never-cached
            // key would -- never silently re-mint authority from the
            // stale, already-invalidated bytes the paused read was
            // holding, and never hang waiting on a network call that
            // should never even be attempted.
            await #expect(throws: AssetError.staleConditionalResponse) {
                _ = try await revalidateTask.value
            }
            let callCountAfterInvalidate = await transport.callCount(for: urls[0])
            #expect(
                callCountAfterInvalidate == 1,
                """
                revalidate(for:) must never issue a conditional request against stale, \
                already-invalidated bytes
                """
            )

            // A subsequent ordinary fetch must behave exactly as if this
            // key had never been cached at all: the invalidation left no
            // partial or resurrected trace behind.
            await transport.enqueue(.success(successResult(etag: "\"v2\"")), for: urls[0])
            let refetched = try await service.asset(for: key)
            #expect(refetched.metadata.etag == "\"v2\"")
        }
    }

    @Test(
        """
        A memory-cache hit already captured by asset(for:) is never returned once a concurrent \
        evictAll() completes while that read was still paused
        """
    )
    func racedAssetMemoryHitAgainstEvictAllIsNeverReturned() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let staleBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 6, height: 6)
            await transport.enqueue(.success(successResult(body: staleBody)), for: urls[0])
            let seeded = try await service.asset(for: key)
            #expect(seeded.payload == staleBody)

            let gate = PauseGate()
            await service.memoryCache.installTestOnlyPauseBeforeReturningHit {
                await gate.markStartedAndWaitForRelease()
            }

            let readTask = Task { try await service.asset(for: key) }
            await gate.waitUntilStarted()

            // While the paused read still only holds the stale bytes it
            // already captured from memory, run a cache-wide invalidation
            // to completion.
            await service.evictAll()
            await gate.release()

            await transport.enqueue(.success(successResult(body: freshBody)), for: urls[0])
            let result = try await readTask.value

            #expect(
                result.payload == freshBody,
                """
                A memory-cache read that raced a completed evictAll() must fall through to a \
                fresh fetch rather than returning the stale bytes it had already captured
                """
            )
            let cachedAfter = try await service.asset(for: key)
            #expect(
                cachedAfter.payload == freshBody,
                "The stale, raced read must never be the value left published in memory"
            )
        }
    }
}
