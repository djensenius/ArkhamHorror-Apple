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
            try await layers.service.evictAll()

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
            try await layers.service.evictAll()

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
            try await layers.service.evictAll()

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

    @Test(
        """
        When evictAll() cannot even enumerate what survives a failed removeAll() (both its \
        own listing and the subsequent survivor enumeration fail), the entry it could not \
        even name is still never trusted after a restart: a fresh AssetCacheService opened \
        over the same directory (no shared in-memory tombstonedKeys/generation state at all) \
        mandatorily revalidates online before ever serving it, rather than relying on any \
        durable disk-side marker this process failed to write
        """
    )
    func evictAllUnenumerableSurvivorsAreStillRevalidatedOnlineAfterRestart() async throws {
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
            // individually in `tombstonedKeys` -- the exact scenario the
            // reviewer flagged as impossible to durably fail closed for
            // on disk. `tombstonedKeys` is purely an in-process, best-
            // effort skip-a-pointless-read optimization: what actually
            // has to hold here is the mandatory-online-revalidation
            // contract every disk hit already passes through in
            // ``AssetCacheService/asset(for:)``, independent of whether
            // this in-memory set ever learned about the key at all.
            await diskCache.directoryAccess.installFaultInjection(listNamesFailuresRemaining: 2)
            try await layers.service.evictAll()

            let failure = await layers.service.lastDiskPersistenceFailure
            #expect(failure != nil, "An unenumerable removeAll() failure must be audited")

            // The entry was never actually deleted (both listing attempts
            // failed before any removal), so its bytes are still
            // physically present. A brand-new `AssetCacheService`/
            // `AssetDiskCache`/`AssetMemoryCache` triple over this exact
            // directory -- simulating a process restart, sharing no
            // in-memory state whatsoever with `layers.service` -- must
            // still never hand those bytes back without a fresh, live
            // network round trip: enqueue a *different* body for the
            // restarted service's own fetch, and confirm the result is
            // that fresh body, never the orphaned original.
            let restartedLayers = try makeService(directory: directory, limits: limits)
            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 5, height: 5)
            await restartedLayers.transport.enqueue(
                .success(successResult(body: freshBody)),
                for: candidateURLs(for: key)[0]
            )
            let servedAfterRestart = try await restartedLayers.service.asset(for: key)
            #expect(
                servedAfterRestart.payload == freshBody,
                """
                A fresh process/instance must never trust an orphaned disk entry it cannot \
                prove was durably invalidated -- it must always revalidate online first
                """
            )
        }
    }

    @Test(
        """
        A key whose metadata-pointer physical deletion fails during `remove(_:)` still \
        durably commits a tombstone disposition (physical cleanup is deliberately \
        best-effort once that disposition itself is durable) -- so `remove(_:)` itself \
        reports success, not a thrown error, and the structurally-intact orphaned bytes it \
        leaves behind are immediately unreadable via `get(_:)`, in this exact same process, \
        with no restart required -- and remain so after a restart too
        """
    )
    func failedPhysicalDeletionStillDurablyTombstonesAndSelfHeals() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let layers = makeService(diskCache: diskCache, limits: limits)

            let key = try cardArtKey("01001")
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let originalBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            try await publishAsset(key, body: originalBody, via: layers)

            // The metadata sidecar's own physical removal fails, so the
            // entry (metadata + payload) survives `remove(_:)` completely
            // intact on disk. This must no longer make `remove(_:)`
            // itself throw: the durable `.retiring`→`.tombstone`
            // disposition transaction (`AssetDiskCache+Disposition.swift`)
            // is what actually makes this key's content unreadable from
            // this point on, and physical cleanup of whatever bytes a
            // failed deletion left behind is intentionally best-effort --
            // conflating that with a genuine disposition-commit failure
            // would wrongly prevent a definitive 404 from ever reporting
            // success purely because some already-unreadable bytes could
            // not be swept.
            await diskCache.directoryAccess.installFaultInjection(
                failRemoveSuffixes: [".meta.json"]
            )
            let outcome = try await diskCache.remove(cacheKey)
            #expect(outcome == .applied)

            // Self-heals immediately, in this exact same process, with no
            // restart at all: `get(_:)` cross-checks the durable
            // disposition against the still-physically-present metadata
            // and refuses to serve a mismatch.
            let hitAfterFailedDeletion = try await diskCache.get(cacheKey)
            #expect(
                hitAfterFailedDeletion == nil,
                "Orphaned bytes a failed physical deletion left behind must never be servable"
            )

            // A brand-new `AssetCacheService`/`AssetDiskCache`/
            // `AssetMemoryCache` triple over this exact directory --
            // simulating a process restart, with none of this process's
            // in-memory `tombstonedKeys`/generation state at all -- must
            // still never serve the orphaned bytes without a fresh, live
            // network round trip: enqueue a *different* body for the
            // restarted service's own fetch and confirm the result is
            // that fresh body, never the structurally-intact original
            // failed deletion left behind.
            let restartedLayers = try makeService(directory: directory, limits: limits)
            let freshBody = AssetImageFixtureBuilder.validAVIF(width: 6, height: 6)
            await restartedLayers.transport.enqueue(
                .success(successResult(body: freshBody)),
                for: candidateURLs(for: key)[0]
            )
            let servedAfterRestart = try await restartedLayers.service.asset(for: key)
            #expect(
                servedAfterRestart.payload == freshBody,
                """
                A fresh process/instance must never trust an orphaned disk entry a failed \
                removal left behind -- it must always revalidate online first
                """
            )
        }
    }

    @Test(
        """
        A genuine failure committing `remove(_:)`'s own durable disposition transaction -- \
        not merely a best-effort physical-deletion failure -- is a thrown typed error, \
        audited via `AssetCacheService.invalidate(_:token:)` into lastDiskPersistenceFailure, \
        since nothing was actually durably confirmed removed in that case
        """
    )
    func failedDispositionCommitDuringRemovalIsAuditedAndTombstonesKey() async throws {
        try await withScratchDirectory { directory in
            let limits = standardLimits()
            let diskCache = try AssetDiskCache(directory: directory, limits: limits)
            let layers = makeService(diskCache: diskCache, limits: limits)

            let key = try cardArtKey("01001")
            let candidates = AssetLocator.candidates(for: key, digest: FakeDigestLookup())
            let cacheKey = AssetCacheKey(for: key, candidates: candidates)
            let originalBody = AssetImageFixtureBuilder.validAVIF(width: 4, height: 4)
            try await publishAsset(key, body: originalBody, via: layers)

            // Fails the disposition file's own temp write (`.applied.tmp`)
            // -- the first of `commitRetractionLocked(for:token:destroy:)`'s
            // two durable commits, attempted before any destructive
            // deletion is even tried -- so nothing about this key's
            // durable disposition can be confirmed changed at all. This
            // is the one failure mode `remove(_:)` must still surface as
            // a thrown typed error.
            await diskCache.directoryAccess.installFaultInjection(
                failSuffixes: [".applied"]
            )
            await #expect(throws: AssetError.self) {
                try await diskCache.remove(cacheKey)
            }

            // `AssetDiskCache.remove(_:)`'s failure is still audited via
            // the service's `invalidate(_:token:)` path in production.
            await #expect(throws: AssetError.self) {
                try await layers.service.invalidate(cacheKey)
            }
            let failure = await layers.service.lastDiskPersistenceFailure
            #expect(failure != nil, "A failed disposition commit must be audited")
            #expect(await layers.service.tombstonedKeys.contains(cacheKey))
        }
    }
}
