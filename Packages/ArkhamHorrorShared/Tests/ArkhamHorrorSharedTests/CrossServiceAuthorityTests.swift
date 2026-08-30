@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Full-stack (``AssetCacheService/asset(for:)`` entrypoint, not the
/// lower-level ``AssetDiskCache`` unit coverage in
/// `AssetDiskCacheWriteGenerationTests.swift`) coverage for the specific
/// cross-service scenarios a cumulative review round flagged as still
/// open even after the durable clear-epoch mechanism landed:
///
/// 1. A sibling service's `evictAll()` must invalidate a *memory-resident*
///    entry another, completely independent service already published --
///    not merely fence an in-flight fetch still awaiting its network
///    response (already covered by
///    `AssetCacheServiceDurableClearEpochTests`).
/// 2. Two independent services' per-key write ordering must be governed
///    by the durable, disk-persisted write generation -- not either
///    service's own private, actor-local bookkeeping -- so an older
///    service's delayed publish can never overwrite a newer sibling's
///    already-applied one, and vice versa. Critically, the *older*
///    service's own caller must also observe that rejection as a typed
///    failure (``AssetError/staleOperation``), never a successfully
///    returned but already-superseded result: a purely disk-side CAS
///    rejection that never propagates back through
///    ``AssetCacheService/publish(_:asset:token:)``/``AssetCacheService/asset(for:)``
///    would leave that service's own caller believing its own stale
///    bytes were the current, cache-consistent answer.
@Suite("AssetCacheService cross-service authority")
struct CrossServiceAuthorityTests {
    private func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("CrossServiceAuthorityScratch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private func standardLimits() -> AssetCacheLimits {
        AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 10_000_000,
            diskBudgetBytes: 10_000_000
        )
    }

    private func makeIndependentService(
        directory: URL,
        limits: AssetCacheLimits
    ) throws -> (service: AssetCacheService, transport: FakeAssetTransport) {
        let transport = FakeAssetTransport()
        let diskCache = try AssetDiskCache(directory: directory, limits: limits)
        let memoryCache = AssetMemoryCache(limits: limits)
        let service = AssetCacheService(
            memoryCache: memoryCache,
            diskCache: diskCache,
            transport: transport,
            digest: FakeDigestLookup(),
            limits: limits
        )
        return (service, transport)
    }

    private func cardArtKey(_ rawCardCode: String = "01001") throws -> AssetKey {
        let identifier = try AssetIdentifier.cardCode(rawCardCode)
        return AssetKey(category: .card(.art, identifier))
    }

    private func candidateURLs(for key: AssetKey) -> [URL] {
        AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            .map { $0.url(base: key.source) }
    }

    private func successResult(
        body: Data = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4),
        etag: String? = nil
    ) -> AssetHTTPResult {
        .success(AssetHTTPResponse(
            body: body,
            contentType: "image/avif",
            etag: etag,
            lastModified: nil
        ))
    }

    @Test(
        """
        Service B's evictAll() must invalidate an entry service A already fully published to \
        its own memory cache (not merely fence a fetch A still has in flight): a subsequent \
        memory hit on A, for the exact same key, must not be trusted purely from A's own \
        untouched in-process bookkeeping, and must instead genuinely re-fetch
        """
    )
    func siblingClearInvalidatesAlreadyPublishedMemoryEntry() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let (serviceA, transportA) = try makeIndependentService(
                directory: directory,
                limits: limits
            )
            let (serviceB, _) = try makeIndependentService(directory: directory, limits: limits)

            let key = try cardArtKey()
            let urls = candidateURLs(for: key)

            // A fully publishes -- no held response, no suspension left
            // open at all -- so this exercises a plain, already-resolved
            // memory hit, not a race against an in-flight operation.
            await transportA.enqueue(.success(successResult()), for: urls[0])
            let firstFetch = try await serviceA.asset(for: key)
            #expect(firstFetch.payload == AssetImageFixtureBuilder.validAVIF(width: 4, height: 4))
            #expect(await transportA.callCount(for: urls[0]) == 1)

            // B, sharing no in-memory state with A at all, clears the
            // shared on-disk directory and durably records that clear.
            try await serviceB.evictAll()

            // A's own next lookup for this exact key must not trust its
            // already-published memory entry: the durable clear epoch it
            // was stamped with no longer matches current.
            await transportA.enqueue(.success(successResult()), for: urls[0])
            let secondFetch = try await serviceA.asset(for: key)
            #expect(secondFetch.payload == AssetImageFixtureBuilder.validAVIF(width: 4, height: 4))
            #expect(
                await transportA.callCount(for: urls[0]) == 2,
                """
                A's second lookup must be a genuine new network fetch: its own memory-resident \
                entry from before B's clear must never be trusted merely because A's own \
                in-process bookkeeping was never itself invalidated
                """
            )
        }
    }

    @Test(
        """
        An older-issued fetch on service A, held up in the network layer, must not overwrite \
        a newer, already-published fetch service B independently completed first for the \
        exact same key -- A's own publish attempt must itself fail as stale (never returning \
        its own already-superseded bytes as if they were still the resolved, cache-consistent \
        answer), and the disk entry a later, fresh service sees must be B's
        """
    )
    func olderIssuedFetchCannotOverwriteNewerSiblingFetch() async throws {
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
            let payloadB = AssetImageFixtureBuilder.validAVIF(width: 8, height: 8)

            await transportA.enqueue(.success(successResult(body: payloadA)), for: urls[0])
            await transportA.hold(urls[0])
            let fetchTaskA = Task<CachedAsset, Error> {
                try await serviceA.asset(for: key)
            }
            await transportA.waitForCallCount(1, for: urls[0])

            // B independently completes a full fetch/publish for the same
            // key while A's own response is still held.
            await transportB.enqueue(.success(successResult(body: payloadB)), for: urls[0])
            let completedB = try await serviceB.asset(for: key)
            #expect(completedB.payload == payloadB)

            // Only now does A's held response resolve -- strictly after
            // B's newer write has already durably landed. A's own
            // publish attempt must be rejected as stale by the disk-
            // durable, cross-instance/cross-process per-key write-
            // generation CAS (``AssetDiskCache/acceptToken(_:currentEpoch:currentApplied:)``),
            // and that rejection must propagate all the way back to this
            // exact caller as a thrown ``AssetError/staleOperation`` --
            // *never* as a successfully returned ``CachedAsset`` carrying
            // A's own already-superseded `payloadA` bytes. A prior
            // revision of this test instead asserted the opposite
            // (`resultA.payload == payloadA`, treating A's own stale
            // fetch as if it had succeeded from A's point of view): that
            // was itself the exact defect a review round required fixing
            // -- an older-issued operation must never deliver its own
            // stale result to its own caller merely because its *local*
            // token bookkeeping never learned a sibling had already won;
            // the disk layer's own CAS rejection must be surfaced back
            // through the full ``AssetCacheService/asset(for:)`` call
            // chain as a definitive, typed failure instead.
            await transportA.release(urls[0])
            await #expect(throws: AssetError.staleOperation) {
                try await fetchTaskA.value
            }

            // The disk entry itself -- the shared, durable resource both
            // services actually write through -- must still hold B's
            // bytes: A's own (older-issued, later-completing) publish
            // attempt must have been rejected as stale by the durable
            // per-key write-generation CAS, never overwriting B's.
            // Inspected directly through a brand-new ``AssetDiskCache``
            // instance over the same directory (rather than through a
            // full ``AssetCacheService.asset(for:)`` round trip, which
            // would require -- entirely separately from what this test
            // is proving -- a scripted mandatory online conditional
            // revalidation before ever trusting a disk-only hit at all).
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let inspectionCache = try AssetDiskCache(directory: directory, limits: limits)
            let onDisk = try #require(try await inspectionCache.get(cacheKey))
            #expect(
                onDisk.payload == payloadB,
                "The durable disk entry must remain B's newer, already-applied publish"
            )
        }
    }

    /// Polls ``AssetCacheService/inFlightRevalidationWaiterCount(forCacheKey:)``
    /// until it reports exactly `count` -- this suite's own analog of
    /// `AssetCacheServiceTests+WaiterSync.swift`'s identical helper, kept
    /// separate purely because ``CrossServiceAuthorityTests`` is its own
    /// `@Suite` struct, not an `extension AssetCacheServiceTests`.
    private func waitForRevalidationWaiterCount(
        _ count: Int,
        cacheKey: AssetCacheKey,
        on service: AssetCacheService,
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while await service.inFlightRevalidationWaiterCount(forCacheKey: cacheKey) != count {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                preconditionFailure(
                    "waitForRevalidationWaiterCount(\(count)) timed out"
                )
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @Test(
        """
        A same-epoch sibling publish for the exact same key (no whole-cache clear at all) must \
        invalidate a service's own already-cached memory entry: the durable clear epoch alone \
        never changes for an ordinary per-key publish, so only a per-key write-generation \
        comparison can catch this
        """
    )
    func siblingSameEpochPublishInvalidatesMemoryEntry() async throws {
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
            let payloadB = AssetImageFixtureBuilder.validAVIF(width: 8, height: 8)
            let payloadC = AssetImageFixtureBuilder.validAVIF(width: 12, height: 12)

            // A fully publishes -- no ETag/Last-Modified at all, so this
            // entry can never be conditionally revalidated later, only
            // ever re-fetched outright -- and caches the result in its
            // own memory.
            await transportA.enqueue(.success(successResult(body: payloadA)), for: urls[0])
            let firstFetch = try await serviceA.asset(for: key)
            #expect(firstFetch.payload == payloadA)

            // B -- sharing no in-memory state with A, but the same disk
            // directory -- looks the same key up. B's memory misses, its
            // disk hit finds A's entry, but that entry carries no
            // validator at all, so it can never be trusted for a
            // conditional request: B falls through to an ordinary,
            // unconditional re-fetch of its own, which durably bumps this
            // key's applied write-generation counter without ever
            // touching the durable clear epoch.
            await transportB.enqueue(.success(successResult(body: payloadB)), for: urls[0])
            let siblingFetch = try await serviceB.asset(for: key)
            #expect(siblingFetch.payload == payloadB)

            // A's own next lookup for this exact key must not trust its
            // still-untouched in-process memory entry: its own stored
            // write-generation (stamped at the first fetch) is now
            // strictly less than the current durable applied ticket B's
            // publish just committed, even though the durable clear epoch
            // itself never changed. A prior revision's memory-hit check
            // compared only the clear epoch and would have wrongly kept
            // serving `payloadA` here forever.
            await transportA.enqueue(.success(successResult(body: payloadC)), for: urls[0])
            let thirdFetch = try await serviceA.asset(for: key)
            #expect(
                thirdFetch.payload != payloadA,
                "A must never keep serving its own now-superseded memory entry"
            )
            #expect(thirdFetch.payload == payloadC)
            #expect(
                await transportA.callCount(for: urls[0]) == 2,
                "A's third lookup must be a genuine new network fetch, not a trusted memory hit"
            )
        }
    }

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
}
