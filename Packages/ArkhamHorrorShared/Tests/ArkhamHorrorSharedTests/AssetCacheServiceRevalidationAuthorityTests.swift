@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of the final cumulative review's finding #1:
/// ``AssetCacheService/revalidate(for:)``'s validated-disk-hit branch must
/// never let its eventual conditional-revalidation network step mint a
/// *fresh* authority token from bytes a concurrent, more-recently-issued
/// invalidation (a direct `invalidate()` or a cache-wide `evictAll()`) has
/// already superseded — even though that same token was still genuinely
/// authoritative the instant this branch finished decoding those bytes.
///
/// Before the fix, `revalidateExisting`/`resolveRevalidationFetchID`
/// unconditionally minted a brand-new token for the network step via
/// `issueToken(for:)`, regardless of whether the token the disk-hit branch
/// had just re-verified was still current. A token freshly issued *after*
/// a clear is, by construction, always the newest one for its key —
/// nothing else has touched that key since — so a 304 response for a
/// request conditioned on the *already-superseded* bytes could still pass
/// that fresh token's own authority check and get written straight back
/// into the cache, resurrecting exactly the content the clear was meant to
/// remove. The fix instead carries the *original* token — the one already
/// re-verified against the freshly decoded bytes — straight through to the
/// network step's own terminal authority check, so an invalidation that
/// happens at any point from decode through to that terminal outcome is
/// never crossed.
///
/// Split from `AssetCacheServiceTests.swift` purely for `file_length`,
/// reusing its `cardArtKey`/`candidateURLs`/`successResult` helpers and
/// `AssetCacheServicePersistenceTests`'s `ServiceLayers`/`makeService`
/// helpers for direct multi-instance `AssetDiskCache` sharing (an empty
/// memory cache in front of an already-populated disk, exactly as after a
/// process restart, so `revalidate(for:)` is forced onto its disk-hit
/// branch rather than short-circuiting on memory).
extension AssetCacheServiceTests {
    /// A minimal rendezvous, identical in shape to
    /// `AssetCacheServiceDiskReadRaceTests.swift`'s private `PauseGate`
    /// (not shared across files, by this suite's established convention).
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
        A validated-disk-hit revalidation's conditional network step never mints fresh \
        authority from bytes an evictAll() already superseded between decode and the network \
        step, so a 304 for those bytes cannot resurrect them
        """
    )
    func racedDiskHitRevalidationAgainstEvictAllNeverResurrectsOnNotModified() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let staleBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)

            // Seed a real, fully-published disk entry (with an ETag, so it
            // is eligible for conditional revalidation) through a first,
            // freshly-wired service — discarded afterward so its own
            // memory cache plays no further part.
            let seedLayers = try makeService(directory: root, limits: limits)
            await seedLayers.transport.enqueue(
                .success(successResult(body: staleBody, etag: "\"v1\"")),
                for: urls[0]
            )
            let seeded = try await seedLayers.service.asset(for: key)
            #expect(seeded.payload == staleBody)
            #expect(seeded.metadata.etag == "\"v1\"")

            // A second, independently-wired service reusing the same
            // underlying `AssetDiskCache` with an empty memory cache,
            // forcing `revalidate(for:)` onto its disk-hit branch.
            let layers = makeService(diskCache: seedLayers.diskCache, limits: limits)

            let gate = PauseGate()
            await layers.service.installTestOnlyPauseBeforeRevalidationNetworkStep {
                await gate.markStartedAndWaitForRelease()
            }

            // The server will answer the eventual conditional request with
            // a 304 against the *same* `"v1"` validator: nothing has
            // actually changed server-side. The only thing that changes
            // is this process's own cache state, via the `evictAll()`
            // below.
            await layers.transport.enqueue(.success(.notModified), for: urls[0])

            let revalidateTask = Task { try await layers.service.revalidate(for: key) }
            await gate.waitUntilStarted()

            // The disk-hit branch has already re-verified its token is
            // authoritative immediately after decoding `staleBody`, and is
            // now paused immediately before carrying that same token
            // through to the conditional network step. Run a cache-wide
            // invalidation to completion here — standing in for whatever
            // more-authoritative concurrent event (a definitive 404 on a
            // distinct in-flight fetch, or an explicit "clear cache"
            // action) actually invalidated this key in production.
            await layers.service.evictAll()
            await gate.release()

            // The stale-authority 304 must never be treated as success:
            // the token the network step's terminal check is gated on was
            // already superseded by the `evictAll()` above before that
            // check ever ran.
            await #expect(throws: AssetError.staleOperation) {
                _ = try await revalidateTask.value
            }

            // Nothing must have been written back into either cache layer
            // under the superseded token: a completely fresh fetch must
            // see this key exactly as if it had never been cached, not the
            // just-cleared `staleBody`.
            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 6, height: 6)
            await layers.transport.enqueue(
                .success(successResult(body: freshBody, etag: "\"v2\"")),
                for: urls[0]
            )
            let refetched = try await layers.service.asset(for: key)
            #expect(
                refetched.payload == freshBody,
                "The evicted, then-stale-304'd bytes must never be resurrected into the cache"
            )
        }
    }
}
