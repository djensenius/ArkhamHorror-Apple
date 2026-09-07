@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of two of the final cumulative review's
/// findings that had no dedicated regression test yet:
///
/// - **A definitive 404's own durable tombstone must survive the
///   automatic retraction that follows it.** A revalidation whose
///   server response is a definitive 404 durably commits a tombstone
///   (``AssetCacheService/invalidate(_:token:)``) under its own authority,
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
///   own applied disposition back to the pristine sentinel — erasing the
///   one piece of durable state that protects this exact key from a
///   stale sibling entry being resurrected over it.
/// - **A 304 revalidation must recompute `accountedByteCount` from a
///   fresh serialization of its own restamped metadata, not reuse the
///   pre-304 entry's stale value**, and must restamp
///   `authorityIDAtPublication` with that revalidation's own freshly
///   minted ``AuthorityID`` rather than leaving the original publish's
///   identifier frozen in place.
extension AssetCacheServiceTests {
    @Test(
        """
        A definitive 404's durable tombstone (committed under this revalidation's own authority) \
        must survive the automatic retraction that follows once every one of its waiters \
        observes the overall candidatesExhausted failure: removeIfApplied must not reset the \
        tombstone's own applied disposition back to the pristine sentinel, since that would erase \
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

            // Seeds a real, validator-bearing entry so the
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

            // The critical assertion: this key's durable applied
            // disposition must still exactly equal the tombstone's own
            // ``AuthorityID`` -- which, by construction of the CAS in
            // ``AssetDiskCache/acceptToken(_:currentEpoch:currentIssued:)``,
            // is also this key's most-recently-*issued* identifier -- and
            // its own ``AssetDiskCache/KeyDispositionKind/tombstone``
            // kind, never reset back to the pristine sentinel
            // a naive retraction would have produced. Asserted directly
            // via ``AssetDiskCache/currentKeyDisposition(for:)`` -- a
            // test/diagnostic-only accessor for exactly this durable
            // state -- rather than indirectly through
            // `beginRevalidationIssuance`'s own provenance check: that
            // check now additionally requires
            // ``AssetDiskCache/KeyDispositionKind/content``, which a
            // tombstone's own disposition can never satisfy regardless of
            // its authority, so it is no longer a usable probe for this
            // specific assertion.
            let disposition = try await layers.diskCache.currentKeyDisposition(for: cacheKey)
            #expect(
                disposition.authorityID == authorityAfterTombstone.issuedAuthorityID,
                """
                The tombstone's own authority must still be the key's current applied \
                disposition after its own automatic retraction ran -- this key's durable \
                "confirmed absent" disposition must never have been reset back to the pristine \
                sentinel
                """
            )
            #expect(
                disposition.kind == .tombstone,
                """
                This key's durable disposition must still be a tombstone (confirmed absent), \
                never silently reverted back to content or left stuck at retiring, after its own \
                automatic retraction observed nothing left to roll back
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
        freshly-serialized metadata, not reuse the pre-304 entry's stale accounted cost, and \
        must restamp authorityIDAtPublication with this revalidation's own freshly minted \
        AuthorityID rather than leaving the original publish's identifier frozen in place.
        """
    )
    func revalidation304RecomputesAccountedByteCountAndRestampsAuthority() async throws {
        try await withScratchDirectory { root in
            let limits = standardLimits()
            let key = try cardArtKey()
            let urls = candidateURLs(for: key)
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let layers = try makeService(directory: root, limits: limits)

            let body = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            await layers.transport.enqueue(
                .success(successResult(body: body, etag: "\"v1\"")),
                for: urls[0]
            )
            let seeded = try await layers.service.asset(for: key)
            #expect(seeded.payload == body)

            var seenAuthorityIDs: Set<AuthorityID> = []
            let seededEntry = try #require(await layers.memoryCache.get(cacheKey))
            try seenAuthorityIDs.insert(#require(seededEntry.authorityID))

            // Nine ordinary successful revalidations (304s). Every one of
            // them must restamp this entry with its own freshly minted,
            // never-before-seen identifier -- the predecessor design's
            // consecutive integer counters made this observable as a
            // monotonic count; a random identifier makes it observable
            // as strict non-repetition, which is the property that
            // actually mattered all along.
            for _ in 0 ..< 9 {
                await layers.transport.enqueue(.success(AssetHTTPResult.notModified), for: urls[0])
                _ = try await layers.service.revalidate(for: key)
                let entry = try #require(await layers.memoryCache.get(cacheKey))
                let authorityID = try #require(entry.authorityID)
                #expect(
                    entry.metadata.authorityIDAtPublication == authorityID,
                    "The sidecar stamp and the in-memory stamp must never diverge after a 304"
                )
                #expect(
                    seenAuthorityIDs.insert(authorityID).inserted,
                    "Every 304 must restamp with a freshly minted, never-reused AuthorityID"
                )
                // Reusing the pre-304 entry's stale accounted cost here
                // would silently mis-bill this entry's true footprint
                // against the memory cache's own quota from this point
                // on. ``AuthorityID``'s fixed 32-hex-character encoding
                // deliberately keeps the *serialized* length stable
                // across restamps, so this assertion is now a direct
                // equality against a fresh recomputation rather than an
                // inequality against the previous value.
                let expectedAccountedBytes = entry.payload.count
                    + entry.metadata.metadataOverheadBytes
                #expect(entry.accountedByteCount == expectedAccountedBytes)
            }
        }
    }
}
