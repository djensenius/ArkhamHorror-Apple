@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of the narrower residual race this review
/// round's finding #2 identified: even after
/// `AssetCacheServiceMemoryHitRaceTests.swift` closed the race where a
/// concurrent `evictAll()`/`invalidate()` completes while the very first
/// `memoryCache.get(_:)` read is still suspended, a second, later window
/// remained open. `asset(for:)`'s and `revalidate(for:)`'s memory-hit
/// branches each perform *two* of their own `await`-based durable checks
/// after that initial memory read already returned a hit --
/// `unchanged(since:for:)`/`clearStateUnchanged(since:for:)` and
/// `memoryEntryStillCurrent(_:storedGeneration:for:)` -- and a same-actor
/// `evictAll()`/`invalidate()` can run to completion during *either* of
/// those two durable round trips (not only during the original
/// `memoryCache.get(_:)` call), bumping `globalGeneration`/
/// `keyClearGeneration`/`keyLatestToken` synchronously in-process, while
/// the durable check in flight -- having already captured its own
/// pre-clear disk-side answer -- still reports "unchanged" once it
/// resumes. Only the final, synchronous, no-further-suspension
/// `localAuthorityStillMatchesSync(_:for:)`/
/// `localClearStateStillMatchesSync(_:for:)` re-check -- gated here by
/// `testOnlyPauseBeforeMemoryFinalCAS`, installed immediately
/// before that final re-check runs -- can still catch this, since it is
/// the only check that reads `keyLatestToken`/`globalGeneration`/
/// `keyClearGeneration` fresh with no intervening suspension of its own.
extension AssetCacheServiceTests {
    /// Identical in shape to `AssetCacheServiceMemoryHitRaceTests.swift`'s
    /// own private `PauseGate` -- see that file's doc comment for why each
    /// race-reproduction file keeps its own copy rather than sharing one.
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
        asset(for:)'s memory hit must not be returned if a concurrent evictAll() completes \
        strictly after both of the memory-hit branch's own durable checks already passed, but \
        before the final synchronous local re-check runs
        """
    )
    func racedAssetMemoryHitAgainstEvictAllBetweenDurableChecksAndFinalCAS() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let staleBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 6, height: 6)
            await transport.enqueue(.success(successResult(body: staleBody)), for: urls[0])
            let seeded = try await service.asset(for: key)
            #expect(seeded.payload == staleBody)

            let gate = PauseGate()
            await service.installTestOnlyPauseBeforeFinalMemoryAuthorityCAS {
                await gate.markStartedAndWaitForRelease()
            }

            let readTask = Task { try await service.asset(for: key) }

            // Returns only once both of `unchanged(since:for:)` and
            // `memoryEntryStillCurrent(_:storedGeneration:for:)` have
            // already completed and reported "still current" — the
            // memory hit captured above is, by construction, still
            // wholly untouched by any clear at this exact instant.
            await gate.waitUntilStarted()

            // Only now, strictly after both durable checks already
            // passed, does a same-actor evictAll() run to completion —
            // exactly the residual window the final synchronous re-check
            // exists to close.
            try await service.evictAll()
            await gate.release()

            await transport.enqueue(.success(successResult(body: freshBody)), for: urls[0])
            let result = try await readTask.value

            #expect(
                result.payload == freshBody,
                """
                A memory hit whose two durable checks already passed before a concurrent \
                evictAll() completed must still be rejected by the final synchronous re-check, \
                falling through to a fresh fetch rather than returning the stale bytes
                """
            )
            let cachedAfter = try await service.asset(for: key)
            #expect(
                cachedAfter.payload == freshBody,
                "The stale, raced read must never be the value left published in memory"
            )
        }
    }

    @Test(
        """
        revalidate(for:)'s memory hit must not be used to mint a fresh authoritative token if a \
        concurrent invalidate() completes strictly after both of the memory-hit branch's own \
        durable checks already passed, but before the final synchronous local re-check runs
        """
    )
    func racedRevalidateMemoryHitAgainstInvalidateBetweenDurableChecksAndFinalCAS() async throws {
        try await withService { service, transport in
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            await transport.enqueue(.success(successResult(etag: "\"v1\"")), for: urls[0])
            let seeded = try await service.asset(for: key)
            #expect(seeded.metadata.etag == "\"v1\"")

            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)

            let gate = PauseGate()
            await service.installTestOnlyPauseBeforeFinalMemoryAuthorityCAS {
                await gate.markStartedAndWaitForRelease()
            }

            let revalidateTask = Task { try await service.revalidate(for: key) }
            await gate.waitUntilStarted()

            // Strictly after both durable checks already passed, a
            // direct, unconditional invalidation for this exact key runs
            // to completion — standing in for whatever more-authoritative
            // concurrent event actually cleared it in production.
            try await service.invalidate(cacheKey)
            await gate.release()

            await #expect(throws: AssetError.staleConditionalResponse) {
                _ = try await revalidateTask.value
            }
            let callCountAfterInvalidate = await transport.callCount(for: urls[0])
            #expect(
                callCountAfterInvalidate == 1,
                """
                revalidate(for:) must never issue a conditional request against stale, \
                already-invalidated bytes purely because both of its durable checks happened to \
                pass before the invalidation completed
                """
            )

            await transport.enqueue(.success(successResult(etag: "\"v2\"")), for: urls[0])
            let refetched = try await service.asset(for: key)
            #expect(refetched.metadata.etag == "\"v2\"")
        }
    }
}
