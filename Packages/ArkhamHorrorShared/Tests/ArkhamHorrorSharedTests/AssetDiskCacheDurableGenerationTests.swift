@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Coverage for ``AssetDiskCache``'s *durable*, on-disk write-generation
/// compare-and-swap (`AssetDiskCache+Generation.swift`) -- the half of the
/// write-ordering contract that survives across two genuinely independent
/// ``AssetDiskCache`` instances (standing in for two separate processes)
/// sharing one cache directory, where ``AssetCacheService/CacheToken``'s
/// own `generation`/`issuance` fields (purely in-process counters, each
/// starting independently from zero) cannot detect a stale write racing
/// against the other instance.
extension AssetDiskCacheTests {
    /// A token whose durable baseline is exactly `diskBaselineGeneration`
    /// -- letting a test drive ``AssetDiskCache/set(_:payload:metadata:token:)``/
    /// ``AssetDiskCache/touch(_:metadata:token:)``/``AssetDiskCache/Removal/remove(_:token:)``'s
    /// durable CAS directly and deterministically, without needing to
    /// race real concurrent tasks against each other. The in-process
    /// `generation`/`issuance` fields are irrelevant here (each test
    /// constructs its own throwaway values), since
    /// ``AssetDiskCache/acceptToken(_:for:)``'s own in-process CAS starts
    /// fresh (`acceptedGeneration == 0`, empty `appliedToken`) for every
    /// freshly-constructed ``AssetDiskCache`` instance and so never
    /// rejects a lone call in these tests on that basis alone.
    func token(
        issuance: Int,
        diskBaselineGeneration: Int,
        diskBaselineClearEpoch: Int = 0,
        generation: Int = 0
    ) -> AssetCacheService.CacheToken {
        AssetCacheService.CacheToken(
            generation: generation,
            issuance: issuance,
            diskBaselineGeneration: diskBaselineGeneration,
            diskBaselineClearEpoch: diskBaselineClearEpoch
        )
    }

    // MARK: - Direct CAS unit coverage

    @Test(
        """
        A set(_:payload:metadata:token:) whose token's durable baseline no longer matches the \
        key's current on-disk generation is a silent no-op, never overwriting the generation \
        that superseded it
        """
    )
    func setRejectsStaleDurableBaseline() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let firstPayload = Data([1, 1, 1])
            let secondPayload = Data([2, 2, 2])

            // Both captured a baseline of `0` (nothing published yet) --
            // exactly as two independent processes racing the very first
            // write for a never-before-cached key would.
            try await cache.set(
                cacheKey,
                payload: firstPayload,
                metadata: metadata(for: cacheKey, payload: firstPayload),
                token: token(issuance: 1, diskBaselineGeneration: 0)
            )
            // A second, distinct write for the same key, still carrying
            // the stale baseline `0` -- as if issued before the first
            // write above was ever durably committed. This must not
            // overwrite the just-published generation.
            try await cache.set(
                cacheKey,
                payload: secondPayload,
                metadata: metadata(for: cacheKey, payload: secondPayload),
                token: token(issuance: 2, diskBaselineGeneration: 0)
            )

            let fetched = try await cache.get(cacheKey)
            #expect(
                fetched?.payload == firstPayload,
                "The stale-baseline write must not have landed"
            )
        }
    }

    @Test(
        """
        A set(_:payload:metadata:token:) whose token captures the current on-disk generation is \
        accepted and advances it, so a subsequent write's own freshly-captured baseline matches \
        the new generation
        """
    )
    func setAcceptsFreshDurableBaseline() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let firstPayload = Data([1, 1, 1])
            let secondPayload = Data([2, 2, 2])

            try await cache.set(
                cacheKey,
                payload: firstPayload,
                metadata: metadata(for: cacheKey, payload: firstPayload),
                token: token(issuance: 1, diskBaselineGeneration: 0)
            )
            let baselineAfterFirst = await cache.currentWriteGeneration(for: cacheKey)
            try await cache.set(
                cacheKey,
                payload: secondPayload,
                metadata: metadata(for: cacheKey, payload: secondPayload),
                token: token(issuance: 2, diskBaselineGeneration: baselineAfterFirst)
            )

            let fetched = try await cache.get(cacheKey)
            #expect(
                fetched?.payload == secondPayload,
                "A freshly-captured baseline must be accepted"
            )
        }
    }

    @Test(
        """
        A touch(_:metadata:token:) whose token's durable baseline no longer matches the key's \
        current on-disk generation is a silent no-op
        """
    )
    func touchRejectsStaleDurableBaseline() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 1, 1])
            var initial = metadata(for: cacheKey, payload: payload)
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: initial,
                token: token(issuance: 1, diskBaselineGeneration: 0)
            )
            // A superseding replacement for the same key (advances the
            // durable generation past what the stale touch below still
            // believes is current). Its own baseline is the *current*
            // on-disk generation (freshly captured), so it is itself a
            // legitimate, accepted write -- only the later stale touch
            // (still holding the original, now-superseded baseline `0`)
            // must be rejected.
            let baselineForReplacement = await cache.currentWriteGeneration(for: cacheKey)
            let replacement = Data([9, 9, 9])
            try await cache.set(
                cacheKey,
                payload: replacement,
                metadata: metadata(for: cacheKey, payload: replacement),
                token: token(issuance: 2, diskBaselineGeneration: baselineForReplacement)
            )

            initial.accessSequence = AssetAccessSequence(999)
            try await cache.touch(
                cacheKey,
                metadata: initial,
                token: token(issuance: 3, diskBaselineGeneration: 0)
            )

            let fetched = try await cache.get(cacheKey)
            #expect(
                fetched?.payload == replacement,
                "The stale touch must not have disturbed the superseding replacement"
            )
        }
    }

    // MARK: - Cross-instance ("two processes") A/B inverse completion

    @Test(
        """
        Two independent AssetDiskCache instances over the same directory: a newer-completing \
        write's durable generation is never overwritten by an older-issued write that captured \
        its baseline before the newer one committed, even though the older one's own disk write \
        happens second
        """
    )
    func crossInstanceOlderIssuedSlowerWriteCannotOverwriteNewerOne() async throws {
        try await withScratchDirectory { directory in
            let processA = try AssetDiskCache(directory: directory, limits: smallLimits())
            let processB = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payloadA = Data([0xA])
            let payloadB = Data([0xB])

            // Both processes observe the same starting baseline (nothing
            // published yet for this key) before either one's own write
            // reaches disk -- exactly the "two processes race the very
            // first write" scenario the durable CAS exists to arbitrate.
            let baselineA = await processA.currentWriteGeneration(for: cacheKey)
            let baselineB = await processB.currentWriteGeneration(for: cacheKey)
            #expect(baselineA == 0)
            #expect(baselineB == 0)

            // Process B's write reaches disk first.
            try await processB.set(
                cacheKey,
                payload: payloadB,
                metadata: metadata(for: cacheKey, payload: payloadB),
                token: token(issuance: 1, diskBaselineGeneration: baselineB)
            )

            // Process A's write -- issued at the same logical moment,
            // simply slower to complete -- reaches disk second, still
            // carrying the baseline it captured before B's write
            // committed.
            try await processA.set(
                cacheKey,
                payload: payloadA,
                metadata: metadata(for: cacheKey, payload: payloadA),
                token: token(issuance: 1, diskBaselineGeneration: baselineA)
            )

            // A fresh third instance (or either existing one) must see
            // only B's durably-committed generation -- A's stale write
            // must never have landed.
            let processC = try AssetDiskCache(directory: directory, limits: smallLimits())
            let fetched = try await processC.get(cacheKey)
            #expect(fetched?.payload == payloadB)
        }
    }

    // MARK: - Removal fences a stale write across a restart

    @Test(
        """
        A removal's durable fence survives a restart: a fresh AssetDiskCache instance opened \
        over the same directory still rejects a stale write whose captured baseline matches the \
        generation that removal invalidated
        """
    )
    func removalFenceSurvivesRestartAndRejectsStaleWrite() async throws {
        try await withScratchDirectory { directory in
            let firstInstance = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let originalPayload = Data([1, 2, 3])

            try await firstInstance.set(
                cacheKey,
                payload: originalPayload,
                metadata: metadata(for: cacheKey, payload: originalPayload),
                token: token(issuance: 1, diskBaselineGeneration: 0)
            )
            // A concurrent reader captures this generation as its own
            // baseline for a (slow) revalidation touch, *before* the
            // removal below runs.
            let staleBaseline = await firstInstance.currentWriteGeneration(for: cacheKey)

            try await firstInstance.remove(
                cacheKey,
                token: token(issuance: 2, diskBaselineGeneration: staleBaseline)
            )

            // Simulates a process restart: a brand-new instance opened
            // over the same on-disk directory, with no in-process
            // knowledge of anything the first instance did.
            let restarted = try AssetDiskCache(directory: directory, limits: smallLimits())
            #expect(try await restarted.get(cacheKey) == nil)

            // The stale touch, finally resuming after the restart with
            // its pre-removal baseline, must still be rejected -- the
            // removal's fence must have survived the restart durably on
            // disk, not merely in the first instance's own memory.
            var staleMetadata = metadata(for: cacheKey, payload: originalPayload)
            staleMetadata.accessSequence = AssetAccessSequence(123)
            try await restarted.touch(
                cacheKey,
                metadata: staleMetadata,
                token: token(issuance: 1, diskBaselineGeneration: staleBaseline)
            )
            #expect(
                try await restarted.get(cacheKey) == nil,
                "The stale touch must not resurrect the entry"
            )

            // A genuinely fresh publish for this exact key is still
            // possible afterward, and clears the fence.
            let freshBaseline = await restarted.currentWriteGeneration(for: cacheKey)
            let freshPayload = Data([9, 9, 9])
            try await restarted.set(
                cacheKey,
                payload: freshPayload,
                metadata: metadata(for: cacheKey, payload: freshPayload),
                token: token(issuance: 2, diskBaselineGeneration: freshBaseline)
            )
            let fetched = try await restarted.get(cacheKey)
            #expect(fetched?.payload == freshPayload)
        }
    }
}
