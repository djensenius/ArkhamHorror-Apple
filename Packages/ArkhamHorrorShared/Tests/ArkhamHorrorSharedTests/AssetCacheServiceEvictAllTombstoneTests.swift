@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Regression coverage for `AssetCacheService+Eviction.swift`'s
/// `evictAll()`: a partially-failed disk clear must conservatively
/// tombstone every key that was persisted immediately before the attempt,
/// not merely whichever keys already happened to be tombstoned beforehand.
/// Split into its own file (rather than folded into
/// `AssetCacheServicePersistenceTests.swift`, which already reuses these
/// same helpers) purely to stay under SwiftLint's `file_length`.
extension AssetCacheServiceTests {
    /// Enqueues `body` as the successful network response for `key`'s
    /// first candidate URL and resolves it, purely to keep the seeding
    /// step in the test below to a single line per key.
    func publishAsset(
        _ key: AssetKey,
        body: Data,
        via layers: ServiceLayers
    ) async throws {
        await layers.transport.enqueue(
            .success(successResult(body: body)),
            for: candidateURLs(for: key)[0]
        )
        _ = try await layers.service.asset(for: key)
    }

    @Test(
        """
        evictAll() tombstones every key that was on disk before a partially-failed \
        removeAll(), not only keys already tombstoned beforehand -- so a whole entry \
        removeAll() could not delete at all (both its metadata sidecar and payload) can \
        never still be served from disk after a claimed "clear cache"
        """
    )
    func evictAllTombstonesEveryPrecedingDiskKeyOnPartialRemovalFailure() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let layers = makeService(diskCache: diskCache, limits: limits)

            let firstKey = try cardArtKey("01001")
            let secondKey = try cardArtKey("01002")
            let firstCandidates = AssetLocator.candidates(for: firstKey, digest: FakeDigestLookup())
            let firstCacheKey = AssetCacheKey(for: firstKey, candidates: firstCandidates)

            let firstOriginalBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            let secondOriginalBody = AssetImageFixtureBuilder.validAVIF(width: 6, height: 6)
            try await publishAsset(firstKey, body: firstOriginalBody, via: layers)
            try await publishAsset(secondKey, body: secondOriginalBody, via: layers)

            // Every one of the first key's on-disk names (its metadata
            // sidecar *and* its payload file both share this prefix) fails
            // to remove, so its whole entry survives `removeAll()`
            // completely intact and independently readable -- exactly the
            // reviewer-reported scenario, not merely a half-deleted pair
            // that `get()`'s own corruption handling would already catch.
            // The second key's entry has no such prefix and is fully
            // removed, so this is a genuine partial (not total) failure.
            await diskCache.directoryAccess.installFaultInjection(
                failRemovePrefixes: ["\(firstCacheKey.digestHex)."]
            )
            await layers.service.evictAll()

            let failure = await layers.service.lastDiskPersistenceFailure
            #expect(failure != nil, "A partially-failed removeAll() must be audited")

            // Confirms the fault injection really did leave the first
            // key's full entry (metadata + payload) intact on disk,
            // independent of the service-level tombstone under test.
            let stillOnDisk = await diskCache.get(firstCacheKey)
            #expect(
                stillOnDisk?.payload == firstOriginalBody,
                "This test must exercise a full-entry removal failure, not a half-deleted one"
            )

            // Neither key had ever failed before this evictAll() call, so
            // before the fix neither would have been tombstoned by the
            // (no-op-on-failure) old catch block -- reproducing the
            // reviewer's exact "not already tombstoned beforehand" case.
            let firstFreshBody = AssetImageFixtureBuilder.validAVIF(width: 5, height: 5)
            let secondFreshBody = AssetImageFixtureBuilder.validAVIF(width: 7, height: 7)
            await layers.transport.enqueue(
                .success(successResult(body: firstFreshBody)),
                for: candidateURLs(for: firstKey)[0]
            )
            await layers.transport.enqueue(
                .success(successResult(body: secondFreshBody)),
                for: candidateURLs(for: secondKey)[0]
            )

            let firstAfterEviction = try await layers.service.asset(for: firstKey)
            #expect(
                firstAfterEviction.payload == firstFreshBody,
                """
                The first key must be refetched from the network, never served from its \
                still-fully-intact-but-supposedly-evicted disk entry
                """
            )
            let secondAfterEviction = try await layers.service.asset(for: secondKey)
            #expect(
                secondAfterEviction.payload == secondFreshBody,
                "The second key must equally be refetched, not served stale from disk"
            )
        }
    }

    @Test(
        """
        evictAll() still tombstones every on-disk key when removeAll()'s own directory \
        listing itself fails (never removing anything), rather than treating an \
        unenumerable disk as if it held no keys at all
        """
    )
    func evictAllTombstonesEveryDiskKeyWhenRemoveAllsOwnListingFails() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let layers = makeService(diskCache: diskCache, limits: limits)

            let firstKey = try cardArtKey("01001")
            let secondKey = try cardArtKey("01002")
            let firstOriginalBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            let secondOriginalBody = AssetImageFixtureBuilder.validAVIF(width: 6, height: 6)
            try await publishAsset(firstKey, body: firstOriginalBody, via: layers)
            try await publishAsset(secondKey, body: secondOriginalBody, via: layers)

            // `removeAll()`'s own single `listNames()` call fails exactly
            // once, so it throws before removing anything at all -- both
            // entries survive completely intact. This is the exact
            // scenario a separate, independently racy pre-attempt snapshot
            // (via `entries()`, which itself also lists and would degrade
            // an equivalent listing failure to an empty `[]`) could never
            // safely recover from.
            await diskCache.directoryAccess.installFaultInjection(listNamesFailuresRemaining: 1)
            await layers.service.evictAll()

            let failure = await layers.service.lastDiskPersistenceFailure
            #expect(failure != nil, "A failed removeAll() must be audited")

            // Neither key's disk entry was ever actually deleted (the
            // failure happened before any removal was attempted), but
            // both must still be tombstoned so a subsequent lookup cannot
            // serve either one back from disk.
            let firstFreshBody = AssetImageFixtureBuilder.validAVIF(width: 5, height: 5)
            let secondFreshBody = AssetImageFixtureBuilder.validAVIF(width: 7, height: 7)
            await layers.transport.enqueue(
                .success(successResult(body: firstFreshBody)),
                for: candidateURLs(for: firstKey)[0]
            )
            await layers.transport.enqueue(
                .success(successResult(body: secondFreshBody)),
                for: candidateURLs(for: secondKey)[0]
            )

            let firstAfterEviction = try await layers.service.asset(for: firstKey)
            #expect(
                firstAfterEviction.payload == firstFreshBody,
                "Must be refetched, never served from its still-intact but evicted disk entry"
            )
            let secondAfterEviction = try await layers.service.asset(for: secondKey)
            #expect(
                secondAfterEviction.payload == secondFreshBody,
                "Must equally be refetched, never served from its still-intact disk entry"
            )
        }
    }
}
