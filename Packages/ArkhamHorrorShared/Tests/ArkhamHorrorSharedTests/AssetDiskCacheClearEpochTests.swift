@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for ``AssetDiskCache``'s durable whole-cache *clear epoch*
/// (`AssetDiskCache+Generation.swift`'s `currentClearEpochLocked`/
/// `persistClearEpochLocked`/`nextClearEpochLocked`, bumped by
/// ``AssetDiskCache/Removal/removeAll()``), which closes an ABA race the
/// per-key durable write-generation (`AssetDiskCacheDurableGenerationTests.swift`)
/// cannot: ``AssetDiskCache/Removal/removeAll()`` invalidates every key at
/// once, including ones with nothing on disk to physically remove (and
/// therefore no per-key tombstone fence recording the clear), so a stale
/// write whose captured per-key baseline happens to still read back as
/// "unchanged" after an intervening create-then-clear cycle must still be
/// rejected by this separate, whole-cache check.
extension AssetDiskCacheTests {
    @Test(
        """
        removeAll() durably bumps a shared clear epoch that a second, independent AssetDiskCache \
        instance over the same directory (standing in for a second process) observes on its very \
        next read, with no special coordination between the two instances
        """
    )
    func removeAllBumpsClearEpochVisibleToASecondInstance() async throws {
        try await withScratchDirectory { directory in
            let first = try AssetDiskCache(directory: directory, limits: smallLimits())
            let second = try AssetDiskCache(directory: directory, limits: smallLimits())

            let epochBeforeClear = await second.currentClearEpoch()
            try await first.removeAll()
            let epochAfterClear = await second.currentClearEpoch()

            #expect(epochAfterClear == epochBeforeClear + 1)
        }
    }

    @Test(
        """
        A key's own per-key durable generation reads back identically (0) both before any write \
        ever occurs and after an intervening create-then-clear cycle -- proving the per-key check \
        alone genuinely cannot distinguish the two, and that the separate clear-epoch check is \
        what closes this gap
        """
    )
    func perKeyGenerationAloneCannotDistinguishNeverWrittenFromClearedAfterWrite() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")

            let neverWrittenGeneration = await cache.currentWriteGeneration(for: cacheKey)

            try await cache.set(
                cacheKey,
                payload: Data([1, 2, 3]),
                metadata: metadata(for: cacheKey, payload: Data([1, 2, 3])),
                token: token(issuance: 1, diskBaselineGeneration: neverWrittenGeneration)
            )
            try await cache.removeAll()

            let afterClearGeneration = await cache.currentWriteGeneration(for: cacheKey)
            #expect(
                afterClearGeneration == neverWrittenGeneration,
                Comment(
                    rawValue: "The per-key generation alone must read back identically in both " +
                        "cases -- this is exactly the ambiguity the clear epoch exists to " +
                        "disambiguate"
                )
            )
        }
    }

    @Test(
        """
        A set(_:payload:metadata:token:) whose token's clear-epoch baseline predates a removeAll() \
        issued (in a second, independent instance standing in for a second process) after that \
        token was captured, but whose per-key generation baseline still coincidentally matches \
        (0, for a key that never existed before the clear), is rejected as a stale ABA write \
        rather than silently landing
        """
    )
    func staleClearEpochBaselineRejectedDespiteMatchingPerKeyGeneration() async throws {
        try await withScratchDirectory { directory in
            let writer = try AssetDiskCache(directory: directory, limits: smallLimits())
            let clearer = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")

            // The writer captures its baseline for a key that has never
            // existed on disk: generation 0, and whatever clear epoch is
            // currently durable (0, for a never-cleared scratch
            // directory) -- exactly what a genuinely fresh first-ever
            // fetch for this key would capture.
            let staleGenerationBaseline = await writer.currentWriteGeneration(for: cacheKey)
            let staleClearEpochBaseline = await writer.currentClearEpoch()
            #expect(staleGenerationBaseline == 0)
            #expect(staleClearEpochBaseline == 0)

            // Meanwhile, in a fully independent instance (standing in for
            // a second process), some other operation creates *and*
            // clears this exact key before the writer's own stale write
            // ever lands. After this cycle, the key's own per-key
            // generation reads back as 0 again (nothing survives to
            // record a per-key tombstone fence for a key `removeAll()`
            // never needed to individually delete anything for) -- but
            // the durable clear epoch has genuinely advanced.
            try await clearer.set(
                cacheKey,
                payload: Data([9, 9, 9]),
                metadata: metadata(for: cacheKey, payload: Data([9, 9, 9])),
                token: token(issuance: 1, diskBaselineGeneration: 0, diskBaselineClearEpoch: 0)
            )
            try await clearer.removeAll()
            let generationAfterCycle = await writer.currentWriteGeneration(for: cacheKey)
            #expect(
                generationAfterCycle == staleGenerationBaseline,
                Comment(
                    rawValue: "Per-key generation must coincidentally match the writer's stale " +
                        "baseline for this scenario to actually exercise the clear-epoch check"
                )
            )

            // The writer's stale write, captured before the create-then-
            // clear cycle above, must still be rejected: its per-key
            // generation baseline alone would (wrongly) look "unchanged",
            // but its clear-epoch baseline no longer matches.
            try await writer.set(
                cacheKey,
                payload: Data([1, 1, 1]),
                metadata: metadata(for: cacheKey, payload: Data([1, 1, 1])),
                token: token(
                    issuance: 1,
                    diskBaselineGeneration: staleGenerationBaseline,
                    diskBaselineClearEpoch: staleClearEpochBaseline
                )
            )

            let fetched = try await writer.get(cacheKey)
            #expect(fetched == nil, "The stale ABA write must not have landed after the clear")
        }
    }

    @Test(
        """
        A fresh write issued after a clear, whose clear-epoch baseline correctly captures the new \
        epoch, is accepted normally -- the epoch check never blocks genuinely new post-clear work
        """
    )
    func freshPostClearWriteWithCurrentEpochBaselineAccepted() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")

            try await cache.removeAll()
            let freshGeneration = await cache.currentWriteGeneration(for: cacheKey)
            let freshEpoch = await cache.currentClearEpoch()
            let currentInProcessGeneration = await cache.acceptedGeneration
            #expect(freshEpoch == 1)

            try await cache.set(
                cacheKey,
                payload: Data([4, 5, 6]),
                metadata: metadata(for: cacheKey, payload: Data([4, 5, 6])),
                token: token(
                    issuance: 1,
                    diskBaselineGeneration: freshGeneration,
                    diskBaselineClearEpoch: freshEpoch,
                    generation: currentInProcessGeneration
                )
            )

            let fetched = try await cache.get(cacheKey)
            #expect(fetched?.payload == Data([4, 5, 6]))
        }
    }

    @Test("The durable clear epoch survives across a fresh AssetDiskCache instance (restart)")
    func clearEpochSurvivesRestart() async throws {
        try await withScratchDirectory { directory in
            let first = try AssetDiskCache(directory: directory, limits: smallLimits())
            try await first.removeAll()
            try await first.removeAll()

            let restarted = try AssetDiskCache(directory: directory, limits: smallLimits())
            let epoch = await restarted.currentClearEpoch()
            #expect(epoch == 2)
        }
    }
}
