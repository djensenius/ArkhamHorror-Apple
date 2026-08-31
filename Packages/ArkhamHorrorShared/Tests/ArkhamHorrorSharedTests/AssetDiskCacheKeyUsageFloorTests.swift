@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic coverage for this review round's remaining findings,
/// all closed by `AssetDiskCache+KeyUsageFloor.swift`'s root-level key
/// usage floor index (finding #1/#2, the actual non-replayable root
/// authority journal a per-key anchor/mirror pair alone cannot ever
/// provide -- see that file's own type-level doc comment) and by
/// ``AssetDiskCache/checkedAdvancedRevision(_:)`` (finding #4, already
/// wired into every revision-advancing commit path).
///
/// These tests deliberately reconstruct the exact "all three of one
/// key's own per-key files consistently lost or rolled back" scenario
/// the floor index exists to catch -- something no fault-injection hook
/// can express (fault injection only ever intercepts this cache's own
/// *future* writes, never bytes a prior, already-committed write left
/// behind), by writing raw bytes directly to those files' own on-disk
/// names, exactly like ``AssetDiskCacheAuthorityRecordMirrorTests.swift``/
/// ``AssetDiskCacheIssuanceAnchorTests.swift`` already do for their own,
/// narrower scenarios.
extension AssetDiskCacheTests {
    /// Builds a raw ``AssetDiskCache/KeyIssuanceAnchor`` payload the same
    /// shape a real commit would have written, for tests that need to
    /// plant one directly rather than let production code write it.
    /// Takes an already-built ``AssetDiskCache/KeyAuthorityRecord`` (see
    /// ``encodedRecord(issuedTicket:ticket:kind:contentHash:revision:)``)
    /// rather than its own flat scalar parameters, purely to stay within
    /// this package's `function_parameter_count` convention.
    func encodedAnchor(
        epoch: Int,
        record: AssetDiskCache.KeyAuthorityRecord
    ) throws -> Data {
        let anchor = AssetDiskCache.KeyIssuanceAnchor(epoch: epoch, record: record)
        return try JSONEncoder.assetCache().encode(anchor)
    }

    /// Overwrites all three of `cacheKey`'s own per-key authority files
    /// (primary, mirror, and issuance anchor) with byte-for-byte the same
    /// snapshot -- simulating a fault (or restored backup) that struck
    /// every one of that key's own files identically, the one failure
    /// mode a primary/mirror/anchor trio written by the same code at the
    /// same time can never, by itself, detect. Takes an already-built
    /// ``AssetDiskCache/KeyAuthorityRecord`` rather than its own flat
    /// scalar parameters, purely to stay within this package's
    /// `function_parameter_count` convention.
    func overwriteAllThreeAuthorityFilesConsistently(
        directory: URL,
        cache: AssetDiskCache,
        cacheKey: AssetCacheKey,
        epoch: Int,
        record: AssetDiskCache.KeyAuthorityRecord
    ) async throws {
        let recordData = try JSONEncoder.assetCache().encode(record)
        try await recordData.write(
            to: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
        )
        try await recordData.write(
            to: mirrorURL(directory: directory, cache: cache, cacheKey: cacheKey)
        )
        let anchorData = try encodedAnchor(epoch: epoch, record: record)
        try await anchorData.write(
            to: anchorURL(directory: directory, cache: cache, cacheKey: cacheKey)
        )
    }

    @Test(
        """
        This review round's finding #1: consistently deleting all three of a key's own \
        per-key authority files after a real publish must fail closed against this cache's \
        own root-level key usage floor index, never silently resume as pristine and let a \
        fresh reservation replay the already-issued ticket
        """
    )
    func fullLossOfAllThreePerKeyFilesFailsClosedAgainstFloorIndex() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            let (issuance, metadata) = try await publishInitialContent(
                cache: cache,
                cacheKey: cacheKey,
                payload: payload
            )
            #expect(issuance.writeGeneration == 1)

            // Deletes every one of this key's own three files at once --
            // no epoch bump, no clear, nothing else in the cache
            // touched. Only this key's own floor entry (in the
            // completely separate, root-level index file) survives to
            // notice the loss.
            let filesToRemove = await [
                primaryURL(directory: directory, cache: cache, cacheKey: cacheKey),
                mirrorURL(directory: directory, cache: cache, cacheKey: cacheKey),
                anchorURL(directory: directory, cache: cache, cacheKey: cacheKey),
            ]
            for url in filesToRemove {
                try FileManager.default.removeItem(at: url)
            }

            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyDisposition(for: cacheKey)
            }
            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: cacheKey)
            }
            _ = metadata
        }
    }

    @Test(
        """
        This review round's finding #1/#2: consistently rolling back all three of a key's own \
        per-key files to an earlier, individually well-formed snapshot -- rather than deleting \
        them -- must fail exactly the same way; a repair must never be attempted toward a \
        candidate that is behind this cache's own root-level floor, regardless of how \
        internally self-consistent that candidate looks
        """
    )
    func consistentRollbackToEarlierValidSnapshotFailsClosed() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let firstPayload = Data([1, 2, 3, 4, 5])
            let (firstIssuance, firstMetadata) = try await publishInitialContent(
                cache: cache,
                cacheKey: cacheKey,
                payload: firstPayload
            )
            #expect(firstIssuance.writeGeneration == 1)

            // A second publish for the exact same key -- ticket 2 -- so
            // the floor index now durably records 2, strictly ahead of
            // the snapshot this test is about to roll back to.
            let secondPayload = Data([9, 9, 9])
            let (secondIssuance, _) = try await publishInitialContent(
                cache: cache,
                cacheKey: cacheKey,
                payload: secondPayload
            )
            #expect(secondIssuance.writeGeneration == 2)

            let epoch = try await cache.currentClearEpoch()
            try await overwriteAllThreeAuthorityFilesConsistently(
                directory: directory,
                cache: cache,
                cacheKey: cacheKey,
                epoch: epoch,
                record: AssetDiskCache.KeyAuthorityRecord(
                    issuedTicket: firstIssuance.writeGeneration,
                    disposition: AssetDiskCache.KeyDisposition(
                        ticket: firstIssuance.writeGeneration,
                        kind: .content,
                        contentHash: firstMetadata.payloadSHA256Hex
                    ),
                    revision: 1
                )
            )

            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyDisposition(for: cacheKey)
            }
            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: cacheKey)
            }
        }
    }

    @Test(
        """
        Locks in the fix for this cache's own self-inflicted regression: when a partial \
        `removeAll()` failure leaves one key's own three per-key files fully intact yet \
        stamped with the prior (pre-clear) epoch, a fresh publish for that same key \
        afterward must still succeed (the ticket floor must relax for a record proven only \
        to be a stale-epoch leftover) rather than being permanently blocked, and the stale \
        survivor's own content must never be served regardless
        """
    )
    func allThreeFilesSurvivingAStaleEpochClearResolvePristineAndSelfHeal() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            let (initialIssuance, _) = try await publishInitialContent(
                cache: cache,
                cacheKey: cacheKey,
                payload: payload
            )
            let preClearEpoch = initialIssuance.clearEpoch

            // Blocks physical removal of every one of this key's own
            // three files (not merely the anchor), so `removeAll()`'s
            // own unconditional epoch bump still lands durably, but this
            // key's entire trio -- primary, mirror, *and* anchor -- is
            // left behind at the pre-clear epoch, exactly the scenario
            // this cache's own floor-index cross-check
            // (`enforceKeyUsageFloorLocked(_:for:anchorWasCurrentEpoch:)`)
            // must agree is safe to treat as pristine, deferring entirely
            // to the anchor's own stale-epoch judgment.
            await cache.directoryAccess.installFaultInjection(
                failRemoveSuffixes: [".applied", ".applied-mirror", ".issuance-anchor"]
            )
            await #expect(throws: AssetError.self) {
                try await cache.removeAll()
            }
            await cache.directoryAccess.installFaultInjection()

            #expect(await FileManager.default.fileExists(
                atPath: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey).path
            ))
            #expect(await FileManager.default.fileExists(
                atPath: mirrorURL(directory: directory, cache: cache, cacheKey: cacheKey).path
            ))
            #expect(await FileManager.default.fileExists(
                atPath: anchorURL(directory: directory, cache: cache, cacheKey: cacheKey).path
            ))

            // The metadata sidecar and payload (not in this fault's own
            // blocked-name list) were genuinely removed by the clear's
            // own sweep, so `get(_:)`'s own independent metadata
            // cross-check (`AssetDiskCache+Read.swift`'s own doc comment)
            // already refuses to serve this stale survivor regardless of
            // what its own surviving authority record says -- this is
            // the actual, load-bearing safety property here, not
            // whatever a bare disposition read happens to report for a
            // key whose own files were never fully swept.
            let hitBeforeFreshPublish = try await cache.get(cacheKey)
            #expect(hitBeforeFreshPublish == nil)

            // The real fix under test: a fresh issuance for this exact
            // key must not be permanently blocked (this cache's own
            // ticket floor must be relaxed for a record proven only to
            // be a stale-epoch leftover). The numeric ticket *value* it
            // receives may legitimately coincide with the stale
            // survivor's own (ticket values are only ever meaningful
            // paired with their own epoch -- see
            // `SecureCacheDirectory+TicketSequence.swift`'s own doc
            // comment for why this cache's global ticket sequence itself
            // is intentionally, safely reset by the exact same clear
            // transaction that bumped the epoch); what actually matters
            // is that this fresh issuance is stamped with the *current*
            // epoch, not the stale one still on this key's own leftover
            // files.
            let currentEpochNow = try await cache.currentClearEpoch()
            let freshIssuance = try await cache.beginIssuance(for: cacheKey)
            #expect(freshIssuance.clearEpoch == currentEpochNow)
            #expect(currentEpochNow != preClearEpoch)
            let freshToken = mirrorTestToken(from: freshIssuance)
            let freshPayload = Data([5, 4, 3, 2, 1])
            let freshMetadata = mirrorTestMetadata(
                for: cacheKey,
                payload: freshPayload,
                issuance: freshIssuance
            )
            try await cache.set(
                cacheKey,
                payload: freshPayload,
                metadata: freshMetadata,
                token: freshToken
            )
            let hit = try await cache.get(cacheKey)
            #expect(hit?.payload == freshPayload)
        }
    }
}
