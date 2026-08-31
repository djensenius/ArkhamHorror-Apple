@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of two of the final cumulative review's
/// findings that had no dedicated regression test yet:
///
/// - **A definitive 404's own durable tombstone must survive the
///   automatic retraction that follows it.** A revalidation whose
///   server response is a definitive 404 durably commits a tombstone
///   (``AssetCacheService/invalidate(_:token:)``) for its own ticket,
///   then throws ``AssetError/candidatesExhausted`` — an overall
///   *failure* result every one of its waiters observes identically.
///   Since not one single waiter ever received a delivered success, the
///   exact same per-waiter-acknowledgement machinery that retracts an
///   abandoned *successful* mutation on cancellation
///   (`AssetCacheServiceRetirementFenceTests.swift`) also runs here,
///   calling ``AssetDiskCache/removeIfApplied(_:token:)`` with this
///   404's own token. Without ``AssetDiskCache/removeIfApplied(_:token:)``'s
///   own "was a metadata sidecar actually removed?" distinction (see
///   that method's doc comment), this would durably reset the tombstone's
///   own applied ticket back to the unapplied sentinel `0` — erasing the
///   one piece of durable state that protects this exact key from a
///   stale sibling entry being resurrected over it.
/// - **A 304 revalidation must recompute `accountedByteCount`, not reuse
///   the pre-304 entry's stale value**, including across a decimal-digit
///   boundary in the serialized metadata size (`writeGenerationAtPublication`
///   going from a single digit to two digits changes the metadata's own
///   serialized byte length, which the entry's accounted cost must
///   reflect).
extension AssetCacheServiceTests {
    @Test(
        """
        A definitive 404's durable tombstone (committed at this exact revalidation's own ticket) \
        must survive the automatic retraction that follows once every one of its waiters \
        observes the overall candidatesExhausted failure: removeIfApplied must not reset the \
        tombstone's own applied ticket back to the unapplied sentinel 0, since that would erase \
        the durable "confirmed absent" disposition a stale sibling entry's resurrection depends \
        on being absent.
        """
    )
    func definitive404TombstoneSurvivesItsOwnAutomaticRetraction() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let layers = try makeService(directory: root, limits: limits)

            // Seeds a real, validator-bearing entry (ticket 1) so the
            // revalidation below has something to condition against.
            let seedBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            await layers.transport.enqueue(
                .success(successResult(body: seedBody, etag: "\"v1\"")),
                for: urls[0]
            )
            let seeded = try await layers.service.asset(for: key)
            #expect(seeded.payload == seedBody)

            // The origin now definitively confirms this exact resolved
            // URL no longer exists.
            await layers.transport.enqueue(.success(AssetHTTPResult.notFound), for: urls[0])

            await #expect(throws: AssetError.candidatesExhausted) {
                _ = try await layers.service.revalidate(for: key)
            }

            // The tombstone commit itself must have already removed any
            // readable metadata/payload for this key.
            let diskEntryAfterTombstone = try await layers.diskCache.get(cacheKey)
            #expect(diskEntryAfterTombstone == nil)

            // The automatic retraction that follows (every waiter of
            // this revalidation observed the same overall failure, so
            // none of them "delivered") runs asynchronously; give it a
            // bounded amount of time to actually reach the disk cache
            // before making the critical assertion below.
            let authorityAfterTombstone = try await waitForStableKeyAuthority(
                layers.diskCache,
                cacheKey: cacheKey
            )

            // The critical assertion: this key's durable applied ticket
            // must still exactly equal the tombstone's own ticket (2 --
            // the second ticket ever issued for this key, after the
            // original seed's ticket 1), never the unapplied sentinel 0
            // a naive retraction would have reset it to. Proven
            // indirectly via `beginRevalidationIssuance`'s own
            // provenance check (a public, already-tested primitive):
            // this must report `expectedAppliedTicket: 2` as still
            // current, and `expectedAppliedTicket: 0` as stale.
            let matchesTombstoneTicket = try await layers.diskCache.beginRevalidationIssuance(
                for: cacheKey,
                expectedClearEpoch: authorityAfterTombstone.clearEpoch,
                expectedAppliedTicket: authorityAfterTombstone.issuedTicket
            )
            #expect(
                matchesTombstoneTicket != nil,
                """
                The tombstone's own ticket must still be the key's current applied ticket after \
                its own automatic retraction ran -- this key's durable "confirmed absent" \
                disposition must never have been erased back to the unapplied sentinel 0
                """
            )
            let matchesSentinelZero = try await layers.diskCache.beginRevalidationIssuance(
                for: cacheKey,
                expectedClearEpoch: authorityAfterTombstone.clearEpoch,
                expectedAppliedTicket: 0
            )
            #expect(
                matchesSentinelZero == nil,
                """
                If this matched, the tombstone's own applied ticket would have been wrongly \
                reset back to the unapplied sentinel 0 by its own automatic retraction
                """
            )
        }
    }

    /// Polls `diskCache.currentKeyAuthority(for:)` until two consecutive
    /// reads agree, as a bounded, deterministic-enough way to wait for an
    /// unawaited retraction `Task` (see
    /// `AssetCacheService+WaiterAcknowledgement.swift`'s
    /// `retractUndeliveredMutation(_:token:)`) to actually reach the disk
    /// cache, without any fixed sleep standing in for its actual
    /// completion.
    private func waitForStableKeyAuthority(
        _ diskCache: AssetDiskCache,
        cacheKey: AssetCacheKey,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws -> AssetDiskCache.KeyAuthoritySnapshot {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        var previous = try await diskCache.currentKeyAuthority(for: cacheKey)
        while true {
            try? await Task.sleep(nanoseconds: 5_000_000)
            let current = try await diskCache.currentKeyAuthority(for: cacheKey)
            if current == previous {
                return current
            }
            previous = current
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                Issue.record("Timed out waiting for this key's durable authority to settle")
                return current
            }
        }
    }

    @Test(
        """
        A 304 revalidation must recompute CachedAsset.accountedByteCount from the entry's own \
        freshly-serialized metadata, not reuse the pre-304 entry's stale accounted cost -- \
        including across a decimal-digit boundary in writeGenerationAtPublication, which changes \
        the metadata's own serialized byte length.
        """
    )
    func revalidation304RecomputesAccountedByteCountAcrossDigitBoundary() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let layers = try makeService(directory: root, limits: limits)

            let body = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)

            // Seeds ticket 1 (a single digit), then issues eight more
            // ordinary successful revalidations (304s, each bumping the
            // ticket by exactly one) so the *tenth* revalidation below
            // crosses the single-digit -> two-digit boundary in its own
            // `writeGenerationAtPublication` (9 -> 10).
            await layers.transport.enqueue(
                .success(successResult(body: body, etag: "\"v1\"")),
                for: urls[0]
            )
            let seeded = try await layers.service.asset(for: key)
            #expect(seeded.payload == body)

            for _ in 0 ..< 8 {
                await layers.transport.enqueue(.success(AssetHTTPResult.notModified), for: urls[0])
                _ = try await layers.service.revalidate(for: key)
            }

            let beforeDigitBoundary = try #require(await layers.memoryCache.get(cacheKey))
            #expect(beforeDigitBoundary.writeGeneration == 9)
            let accountedBeforeDigitBoundary = beforeDigitBoundary.accountedByteCount

            await layers.transport.enqueue(.success(AssetHTTPResult.notModified), for: urls[0])
            _ = try await layers.service.revalidate(for: key)

            let afterDigitBoundary = try #require(await layers.memoryCache.get(cacheKey))
            #expect(afterDigitBoundary.writeGeneration == 10)

            // The serialized metadata's own byte length must reflect the
            // new (longer, by one ASCII digit)
            // `writeGenerationAtPublication` value, and the accounted
            // cost must track it exactly -- reusing the pre-304 entry's
            // stale accounted cost here would silently under-count this
            // entry's true footprint against the memory cache's own
            // quota from this point on.
            let expectedAccountedBytes = afterDigitBoundary.payload.count
                + afterDigitBoundary.metadata.metadataOverheadBytes
            #expect(afterDigitBoundary.accountedByteCount == expectedAccountedBytes)
            #expect(afterDigitBoundary.accountedByteCount != accountedBeforeDigitBoundary)
        }
    }
}
