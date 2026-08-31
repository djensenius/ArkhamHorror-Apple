@testable import ArkhamHorrorShared
import Foundation
import Testing

/// The compaction/quota-bounding half of
/// `AssetDiskCacheKeyUsageFloorTests.swift`'s own coverage for this
/// review round's finding #3 (this cache's own root-level key usage
/// floor index must itself be bounded and reclaimed, never left to grow
/// forever) and finding #4 (`revision` must fail closed at `Int.max`
/// rather than trapping) -- split into its own file purely to keep that
/// file within this package's `file_length` convention. See that file's
/// own type-level doc comment for the full reasoning shared by both.
extension AssetDiskCacheTests {
    /// Publishes and then durably tombstones `count` (default 8) brand
    /// new, individually distinct keys, returning them in publish order
    /// -- the "genuinely reclaimable" fixture shared by
    /// ``compactionReclaimsConfirmedTombstonedEntriesAndStaysBounded()``.
    /// Extracted purely to keep that test's own body within this
    /// package's `function_body_length` convention.
    private func publishAndTombstoneReclaimableKeys(
        cache: AssetDiskCache,
        count: Int = 8
    ) async throws -> [AssetCacheKey] {
        var reclaimableKeys: [AssetCacheKey] = []
        for index in 0 ..< count {
            let cacheKey = try key(String(format: "%05d", index))
            let payload = Data([UInt8(index)])
            let (issuance, _) = try await publishInitialContent(
                cache: cache,
                cacheKey: cacheKey,
                payload: payload
            )
            let token = AssetCacheService.CacheToken(
                generation: 0,
                issuance: 0,
                durableClearEpoch: issuance.clearEpoch,
                diskWriteGeneration: issuance.writeGeneration
            )
            try await cache.removeIfApplied(cacheKey, token: token)
            reclaimableKeys.append(cacheKey)
        }
        return reclaimableKeys
    }

    /// Directly inflates `cache`'s own root-level floor index (persisted
    /// at `indexURL`) with a large number of purely synthetic filler
    /// entries -- no corresponding on-disk per-key files exist for these,
    /// so compaction must (and, per its own contract, does) leave them
    /// entirely alone; they exist purely to push this index's own entry
    /// count past ``AssetDiskCache/maxKeyUsageFloorIndexEntries`` so the
    /// next eviction pass actually attempts a compaction at all, without
    /// needing thousands of real, genuinely slow per-key disk publishes
    /// to reach that same threshold. Returns the entry count written, so
    /// the caller can assert it is indeed past that bound. Extracted
    /// purely to keep
    /// ``compactionReclaimsConfirmedTombstonedEntriesAndStaysBounded()``'s
    /// own body within this package's `function_body_length` convention.
    private func inflateFloorIndexWithFillerEntries(
        cache: AssetDiskCache,
        indexURL: URL,
        reclaimableKeys: [AssetCacheKey]
    ) async throws -> Int {
        let epoch = try await cache.currentClearEpoch()
        var entries: [String: AssetDiskCache.KeyUsageFloorEntry] = [:]
        for index in 0 ..< (AssetDiskCache.maxKeyUsageFloorIndexEntries + 16) {
            let fillerHex = String(format: "%064x", index)
            entries[fillerHex] = AssetDiskCache.KeyUsageFloorEntry(issuedTicket: index + 1)
        }
        for reclaimableKey in reclaimableKeys {
            entries[reclaimableKey.digestHex] = AssetDiskCache.KeyUsageFloorEntry(
                issuedTicket: entries[reclaimableKey.digestHex]?.issuedTicket ?? 1
            )
        }
        let inflatedIndex = AssetDiskCache.KeyUsageFloorIndex(epoch: epoch, entries: entries)
        try JSONEncoder.assetCache().encode(inflatedIndex).write(to: indexURL)
        return entries.count
    }

    @Test(
        """
        This review round's finding #3: once this cache's own root-level key usage floor \
        index has grown past its fixed bound, the next eviction pass reclaims every entry \
        this cache can durably confirm is both tombstoned and fully removable, shrinking the \
        index back down rather than growing it forever -- and a fresh reservation for a \
        reclaimed key afterward still receives a ticket that has never been issued before, \
        by construction of this cache's own cross-key global ticket sequence
        """
    )
    func compactionReclaimsConfirmedTombstonedEntriesAndStaysBounded() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())

            // A handful of *real* keys, genuinely published then
            // genuinely retracted to a durable tombstone -- these are
            // the entries this pass must actually be able to reclaim.
            let reclaimableKeys = try await publishAndTombstoneReclaimableKeys(cache: cache)

            // Directly inflates this cache's own root-level floor index
            // with a large number of purely synthetic filler entries --
            // no corresponding on-disk per-key files exist for these, so
            // compaction must (and, per its own contract, does) leave
            // them entirely alone; they exist purely to push this
            // index's own entry count past
            // ``AssetDiskCache/maxKeyUsageFloorIndexEntries`` so the next
            // eviction pass actually attempts a compaction at all,
            // without this test needing thousands of real, genuinely
            // slow per-key disk publishes to reach that same threshold.
            let indexURL = directory.appendingPathComponent(
                AssetDiskCache.keyUsageFloorIndexFileName
            )
            let beforeCount = try await inflateFloorIndexWithFillerEntries(
                cache: cache,
                indexURL: indexURL,
                reclaimableKeys: reclaimableKeys
            )
            #expect(beforeCount > AssetDiskCache.maxKeyUsageFloorIndexEntries)

            // Any `set` call runs `evictIfNeeded()` as its own trailing
            // recovery pass (see that method's own doc comment), which
            // is exactly where compaction is folded in -- so publishing
            // one more, entirely unrelated key is enough to trigger it.
            let triggerKey = try key("99999")
            _ = try await publishInitialContent(
                cache: cache,
                cacheKey: triggerKey,
                payload: Data([7])
            )

            let rawIndexData = try Data(contentsOf: indexURL)
            let decodedIndex = try JSONDecoder.assetCache().decode(
                AssetDiskCache.KeyUsageFloorIndex.self,
                from: rawIndexData
            )
            #expect(
                decodedIndex.entries.count < beforeCount,
                """
                A compaction pass must have reclaimed at least the confirmed-tombstoned real \
                keys' own entries
                """
            )
            for reclaimableKey in reclaimableKeys {
                #expect(decodedIndex.entries[reclaimableKey.digestHex] == nil)
            }

            // A fresh reservation for a reclaimed key must still receive
            // a ticket that has never been issued before anywhere in
            // this cache directory -- guaranteed by the independent,
            // cross-key global ticket sequence, not by this now-cleared
            // floor entry.
            let allPriorTickets = Set((0 ..< 8).map { $0 + 1 } + [9])
            let reissuance = try await cache.beginIssuance(for: reclaimableKeys[0])
            #expect(!allPriorTickets.contains(reissuance.writeGeneration))
            #expect(reissuance.writeGeneration > allPriorTickets.max() ?? 0)
        }
    }

    @Test(
        """
        This review round's finding #3: issuing a fresh ticket for a brand-new key while \
        disk writes are durably disabled must fail closed and must never grow this cache's \
        own root-level key usage floor index
        """
    )
    func issuanceHonorsDiskWritesDisabledAndNeverGrowsFloorIndex() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            // Establishes the root (and this index's own genuinely-fresh
            // bootstrap) before disabling writes, exactly like every
            // other disk-writes-disabled test in this suite.
            _ = try await cache.currentClearEpoch()
            // Directly plants the whole-cache disk-writes-disabled
            // marker this cache's own gate
            // (``AssetDiskCache/requireDiskWritesEnabledLocked()``)
            // checks purely by this file's existence, not its content --
            // mirrors how a prior, already-durable disabling would
            // actually be observed on a fresh process start.
            try Data().write(
                to: directory.appendingPathComponent(AssetDiskCache.diskWritesDisabledMarkerName)
            )

            let indexURL = directory.appendingPathComponent(
                AssetDiskCache.keyUsageFloorIndexFileName
            )
            let beforeData = try Data(contentsOf: indexURL)

            let cacheKey = try key("01001")
            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: cacheKey)
            }

            let afterData = try Data(contentsOf: indexURL)
            #expect(
                beforeData == afterData,
                """
                A rejected issuance while disk writes are disabled must never touch this \
                cache's own root-level floor index
                """
            )
        }
    }

    @Test(
        """
        This review round's finding #4: advancing a key's own authority revision counter at \
        `Int.max` must fail closed with a typed persistence error rather than trapping the \
        whole process on integer overflow
        """
    )
    func revisionAtIntMaxFailsClosedInsteadOfTrapping() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            let (issuance, metadata) = try await publishInitialContent(
                cache: cache,
                cacheKey: cacheKey,
                payload: payload
            )

            // Directly plants a record at `Int.max` revision -- this
            // cache never durably reaches that value through ordinary
            // use, so this is the only way to exercise the boundary
            // deterministically.
            let epoch = try await cache.currentClearEpoch()
            try await overwriteAllThreeAuthorityFilesConsistently(
                directory: directory,
                cache: cache,
                cacheKey: cacheKey,
                epoch: epoch,
                record: AssetDiskCache.KeyAuthorityRecord(
                    issuedTicket: issuance.writeGeneration,
                    disposition: AssetDiskCache.KeyDisposition(
                        ticket: issuance.writeGeneration,
                        kind: .content,
                        contentHash: metadata.payloadSHA256Hex
                    ),
                    revision: Int.max
                )
            )
            // The floor index must agree this ticket is already this
            // key's own recorded floor, so the boundary condition below
            // is exercised in isolation rather than incidentally also
            // tripping this suite's own finding #1 protection.
            let indexURL = directory.appendingPathComponent(
                AssetDiskCache.keyUsageFloorIndexFileName
            )
            let currentIndex = try JSONDecoder.assetCache().decode(
                AssetDiskCache.KeyUsageFloorIndex.self,
                from: Data(contentsOf: indexURL)
            )
            var updated = currentIndex
            updated.entries[cacheKey.digestHex] = AssetDiskCache.KeyUsageFloorEntry(
                issuedTicket: issuance.writeGeneration
            )
            try JSONEncoder.assetCache().encode(updated).write(to: indexURL)

            let disposition = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(disposition.kind == .content, "The planted record must read back trusted")

            let token = AssetCacheService.CacheToken(
                generation: 0,
                issuance: 0,
                durableClearEpoch: issuance.clearEpoch,
                diskWriteGeneration: issuance.writeGeneration
            )
            await #expect(throws: AssetError.self) {
                try await cache.removeIfApplied(cacheKey, token: token)
            }
        }
    }
}
