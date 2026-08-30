@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of the final cumulative review's finding #1:
/// ``AssetCacheService/revalidate(for:)``'s validated-disk-hit branch must
/// never let a concurrent, more-recently-issued invalidation (a direct
/// `invalidate()` or a cache-wide `evictAll()`) that supersedes its
/// already-decoded bytes result in those bytes being resurrected — even
/// though they were still genuinely current the instant this branch
/// finished decoding them.
///
/// The disk-hit branch itself never issues or reserves any durable
/// per-key authority; it only re-verifies its own read-only snapshot is
/// still unchanged immediately after decoding. Fresh authority is derived
/// only later, atomically alongside the join-or-create decision for the
/// actual (revalidation or fallback-fetch) operation, directly from the
/// decoded entry's own historical publication stamp
/// (`beginRevalidationIssuance`). When a concurrent `evictAll()`/
/// `invalidate()` has superseded that stamp by the time this decision
/// runs, it fails closed (`AssetError.revalidationProvenanceUnavailable`),
/// and the disk-hit branch catches that and falls through to a genuinely
/// fresh, *unconditional* fetch — exactly as if the disk entry had never
/// existed — rather than ever sending a conditional request paired with
/// the now-superseded bytes at all. This is stricter than merely gating a
/// conditional network step's terminal outcome on a frozen token: the
/// stale bytes are discarded before any conditional request is even
/// attempted, so a 304 for them can never be received, let alone
/// resurrect them.
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
        A validated-disk-hit revalidation never carries a conditional request forward from \
        bytes an evictAll() already superseded between decode and the network step: it \
        instead discards those bytes and falls through to a genuinely fresh, unconditional \
        fetch, so a 304 for the superseded bytes can never even be requested, let alone \
        resurrect them
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

            // The evictAll() below invalidates `staleBody`'s own
            // historical publication stamp before this branch's
            // join-or-create decision ever re-derives fresh authority
            // from it. That decision (`beginRevalidationIssuance`) then
            // fails closed with `AssetError.revalidationProvenanceUnavailable`,
            // which this branch catches and treats exactly like a fresh
            // cache miss: an ordinary *unconditional* fetch of `urls[0]`,
            // never a conditional request paired with the
            // now-superseded `staleBody`/`"v1"` bytes at all. The queued
            // response below is that unconditional fetch's genuinely
            // fresh content — a real 304 for the stale bytes is never
            // even attempted, so nothing needs to be enqueued to answer
            // one.
            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 6, height: 6)
            await layers.transport.enqueue(
                .success(successResult(body: freshBody, etag: "\"v2\"")),
                for: urls[0]
            )

            let revalidateTask = Task { try await layers.service.revalidate(for: key) }
            await gate.waitUntilStarted()

            // The disk-hit branch has already re-verified its snapshot is
            // still current immediately after decoding `staleBody`, and is
            // now paused immediately before carrying that snapshot
            // through to the join-or-create decision. Run a cache-wide
            // invalidation to completion here — standing in for whatever
            // more-authoritative concurrent event (a definitive 404 on a
            // distinct in-flight fetch, or an explicit "clear cache"
            // action) actually invalidated this key in production.
            try await layers.service.evictAll()
            await gate.release()

            // The now-stale `staleBody` must never be treated as still
            // current: the join-or-create decision reached immediately
            // after release must reject `staleBody`'s own historical
            // stamp (superseded by the `evictAll()` above) and fall
            // through to the freshly-enqueued unconditional fetch above,
            // so this call succeeds with the fresh content rather than
            // resurrecting `staleBody`.
            let resolved = try await revalidateTask.value
            #expect(
                resolved.payload == freshBody,
                "The evicted, then-superseded bytes must never be resurrected into the cache"
            )
            #expect(resolved.metadata.etag == "\"v2\"")

            // A subsequent, independent call must observe exactly this
            // freshly-published entry from cache, with no further
            // network access needed.
            let refetched = try await layers.service.asset(for: key)
            #expect(refetched.payload == freshBody)
        }
    }
}
