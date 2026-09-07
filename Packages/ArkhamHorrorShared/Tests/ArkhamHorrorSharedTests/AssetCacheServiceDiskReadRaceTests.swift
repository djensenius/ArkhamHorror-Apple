@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of the exact race the 7th cumulative
/// review's finding #2 (superseded by the 8th review's finding #3, whose
/// per-key issuance-token/generation authority this exercises at the
/// `AssetCacheService`↔`AssetDiskCache` boundary specifically) requires
/// closed: a disk *read* that has already validated a hit in-memory must
/// never be promoted/returned once something more authoritative for that
/// exact key — here, `evictAll()`'s cache-wide invalidation — completed
/// while the read was still in flight, even though the read itself
/// encountered no error and returned a structurally valid payload.
///
/// Split from `AssetCacheServiceTests.swift` purely for `file_length`,
/// reusing its `withScratchDirectory`/`cardArtKey`/`candidateURLs`/
/// `successResult` helpers, and from `AssetCacheServicePersistenceTests`'s
/// `ServiceLayers`/`makeService` helpers for direct `AssetDiskCache`
/// access (needed here to install
/// `AssetDiskCache.installTestOnlyPauseBeforeReturningHit`, a hook that
/// exists purely so this exact interleaving can be forced deterministically
/// rather than depend on incidental actor-scheduling order).
extension AssetCacheServiceTests {
    /// A minimal rendezvous: lets the test block until a paused disk read
    /// has actually reached its pause point (so `evictAll()` is only
    /// invoked once the read has a validated hit captured in memory, not
    /// merely enqueued), then lets the test resume that read on demand.
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

        /// Called from inside the paused `get(_:)` call itself: marks
        /// the pause as reached (waking `waitUntilStarted()`), then
        /// suspends until `release()` is called.
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
        A disk read that already captured a valid hit is never promoted or returned \
        once evictAll() completes while that read was still paused
        """
    )
    func racedDiskHitAgainstEvictAllIsNeverPromoted() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let staleBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 6, height: 6)

            // Seed a real, fully-published disk entry through a first,
            // freshly-wired service — deliberately discarded afterward so
            // its own memory cache (which would otherwise short-circuit
            // the very disk-hit path this test needs to race) plays no
            // further part.
            let seedLayers = try makeService(directory: root, limits: limits)
            await seedLayers.transport.enqueue(
                .success(successResult(body: staleBody)),
                for: urls[0]
            )
            let seeded = try await seedLayers.service.asset(for: key)
            #expect(seeded.payload == staleBody)

            // A second, independently-wired service reusing the *same*
            // underlying `AssetDiskCache` — an empty memory cache in front
            // of an already-populated disk, exactly as after a process
            // restart, so `asset(for:)` below is forced onto the disk-hit
            // path rather than short-circuiting on memory.
            let layers = makeService(diskCache: seedLayers.diskCache, limits: limits)

            let gate = PauseGate()
            await layers.diskCache.installTestOnlyPauseBeforeReturningHit {
                await gate.markStartedAndWaitForRelease()
            }

            let readTask = Task { try await layers.service.asset(for: key) }
            await gate.waitUntilStarted()

            // While the paused read still holds only the stale, pre
            // -eviction bytes it already validated, run a cache-wide
            // invalidation to completion. The disk actor is free to
            // service it: the paused `get(_:)` call already yielded via
            // its own internal `await` at the pause point.
            try await layers.service.evictAll()

            // Only once eviction has fully completed does the test let
            // the stale read actually return to its caller, so the
            // interleaving being asserted below is unambiguous rather
            // than a race against `evictAll()`'s own completion.
            await gate.release()

            await layers.transport.enqueue(.success(successResult(body: freshBody)), for: urls[0])
            let result = try await readTask.value

            #expect(
                result.payload == freshBody,
                """
                A read that raced a completed evictAll() must fall through to a fresh \
                fetch rather than resurrecting the stale bytes it had already validated
                """
            )
            let cachedAfter = try await layers.service.asset(for: key)
            #expect(
                cachedAfter.payload == freshBody,
                "The stale, raced read must never be the value left published in memory"
            )
        }
    }
}
