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
            let stillOnDisk = try await diskCache.get(firstCacheKey)
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
        evictAll()'s survivor snapshot after a partially-failed removeAll() filters out \
        any raw directory entry name that is not a genuine 64-lowercase-hex key hash \
        before ever tombstoning it, so a corrupt/attacker-planted file name can never \
        inflate tombstonedKeys with a bogus AssetCacheKey
        """
    )
    func evictAllFiltersNonHexSurvivorNamesBeforeTombstoning() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let layers = makeService(diskCache: diskCache, limits: limits)

            let firstKey = try cardArtKey("01001")
            let firstCandidates = AssetLocator.candidates(for: firstKey, digest: FakeDigestLookup())
            let firstCacheKey = AssetCacheKey(for: firstKey, candidates: firstCandidates)
            let firstOriginalBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            try await publishAsset(firstKey, body: firstOriginalBody, via: layers)

            // A raw file planted directly on disk (bypassing every cache
            // API), whose name is not a genuine key hash at all -- the
            // same shape `entryKeyHashes()` deliberately still surfaces
            // (a corrupt/undecodable/attacker-controlled entry), which
            // must never be handed straight to `AssetCacheKey(digestHex:)`.
            let bogusName = "not-a-real-hex-key-hash.bin"
            try Data("bogus payload".utf8).write(to: directory.appendingPathComponent(bogusName))

            // Both the real key's entry *and* the bogus file must survive
            // `removeAll()` intact, so both are present in the post-
            // failure survivor snapshot `evictAll()` takes.
            await diskCache.directoryAccess.installFaultInjection(
                failRemovePrefixes: ["\(firstCacheKey.digestHex).", "not-a-real-hex-key-hash"]
            )
            await layers.service.evictAll()

            let failure = await layers.service.lastDiskPersistenceFailure
            #expect(failure != nil, "A partially-failed removeAll() must be audited")

            let tombstoned = await layers.service.tombstonedKeys
            #expect(
                tombstoned == [firstCacheKey],
                "Only the genuine hex-shaped survivor may be tombstoned, never the bogus name"
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

    /// Builds a minimal, self-consistent `AssetCacheMetadata` for
    /// `cacheKey`/`body`/`width`/`height`, purely to keep the tombstone
    /// -durability tests below (which each need several such values)
    /// short enough to stay under SwiftLint's `function_body_length`.
    func avifMetadata(
        for cacheKey: AssetCacheKey,
        body: Data,
        width: Int,
        height: Int
    ) -> AssetCacheMetadata {
        AssetCacheMetadata(
            cacheKeyHex: cacheKey.digestHex,
            contentType: "image/avif",
            encodedByteCount: body.count,
            width: width,
            height: height,
            payloadSHA256Hex: AssetPayloadHasher.sha256Hex(body),
            etag: nil,
            lastModified: nil,
            resolvedURLString: "https://example.com/\(cacheKey.digestHex)",
            insertedAt: Date(),
            accessSequence: AssetAccessSequence(0)
        )
    }

    @Test(
        """
        When evictAll() cannot even enumerate what survives a failed removeAll() (both its \
        own listing and the subsequent survivor enumeration fail), it fails closed for the \
        entire disk cache via a durable marker -- a key that was never individually \
        tombstoned (because no enumeration ever succeeded to name it) still cannot be served \
        from disk, and a fresh instance opened over the same directory inherits the same \
        fail-closed state until a fully successful removeAll() clears it
        """
    )
    func evictAllFailsClosedForTheWholeDiskCacheWhenSurvivorsAreUnenumerable() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let layers = makeService(diskCache: diskCache, limits: limits)

            let key = try cardArtKey("01001")
            let originalBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            try await publishAsset(key, body: originalBody, via: layers)

            // Both `removeAll()`'s own listing *and* the catch block's
            // follow-up `entryKeyHashes()` listing fail, so this call
            // truly cannot name any specific surviving key to tombstone
            // individually -- the exact scenario that requires the
            // whole-cache fail-closed marker rather than a per-key
            // tombstone.
            await diskCache.directoryAccess.installFaultInjection(listNamesFailuresRemaining: 2)
            await layers.service.evictAll()

            let failure = await layers.service.lastDiskPersistenceFailure
            #expect(failure != nil, "An unenumerable removeAll() failure must be audited")

            // The entry was never actually deleted (both listing attempts
            // failed before any removal), yet a *fresh* `AssetDiskCache`
            // instance over this exact directory -- simulating a process
            // restart, with none of this process's in-memory
            // `tombstonedKeys` state -- must still refuse to serve it,
            // because the durable marker lives on disk, not in memory.
            let restarted = try AssetDiskCache(directory: directory, limits: limits)
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let servedAfterRestart = try await restarted.get(cacheKey)
            #expect(
                servedAfterRestart == nil,
                "A fresh instance must inherit the durable fail-closed marker from disk"
            )

            // A fully successful removeAll() (no fault injection this
            // time) is the one event that durably clears the marker,
            // after which a fresh publish is servable again.
            try await restarted.removeAll()
            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 5, height: 5)
            let freshMetadata = avifMetadata(for: cacheKey, body: freshBody, width: 5, height: 5)
            try await restarted.set(cacheKey, payload: freshBody, metadata: freshMetadata)
            let servedAfterClear = try await restarted.get(cacheKey)
            #expect(servedAfterClear?.payload == freshBody)
        }
    }

    @Test(
        """
        A key whose metadata-pointer deletion fails is durably tombstoned on disk (not merely \
        in this process's memory): a fresh AssetDiskCache instance opened over the same \
        directory -- simulating a restart -- still refuses to serve the structurally-intact \
        entry that failed deletion left behind, and a later successful publish for that exact \
        key clears the durable tombstone so the fresh generation becomes servable again
        """
    )
    func failedRemovalTombstoneSurvivesRestartAndIsClearedByAFreshPublish() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let firstInstance = try AssetDiskCache(directory: directory, limits: limits)
            let key = try cardArtKey("01001")
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let originalBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            let originalMetadata = avifMetadata(
                for: cacheKey, body: originalBody, width: 4, height: 4
            )
            try await firstInstance.set(cacheKey, payload: originalBody, metadata: originalMetadata)

            // The metadata sidecar's own removal fails, so the entry
            // (metadata + payload) survives `remove(_:)` completely
            // intact on disk -- the only path that must fall back to a
            // durable tombstone.
            await firstInstance.directoryAccess.installFaultInjection(
                failRemoveSuffixes: [".meta.json"]
            )
            await #expect(throws: AssetError.self) {
                try await firstInstance.remove(cacheKey)
            }
            let stillReadableInSameInstance = try await firstInstance.get(cacheKey)
            #expect(
                stillReadableInSameInstance == nil,
                "The durable tombstone must block reads immediately, in the same instance"
            )

            // A brand-new instance over the same directory (no shared
            // in-memory state at all) must still refuse to serve it.
            let restarted = try AssetDiskCache(directory: directory, limits: limits)
            #expect(try await restarted.get(cacheKey) == nil)

            // A later, definitively fresh publish for this exact key
            // clears the durable tombstone and becomes servable again.
            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 6, height: 6)
            let freshMetadata = avifMetadata(for: cacheKey, body: freshBody, width: 6, height: 6)
            try await restarted.set(cacheKey, payload: freshBody, metadata: freshMetadata)
            let servedAfterFreshPublish = try await restarted.get(cacheKey)
            #expect(servedAfterFreshPublish?.payload == freshBody)
        }
    }
}
