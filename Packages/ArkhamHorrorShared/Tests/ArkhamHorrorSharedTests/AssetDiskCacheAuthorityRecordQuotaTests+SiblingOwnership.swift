@testable import ArkhamHorrorShared
import Foundation
import Testing

private struct IssuedAuthorityOperation {
    let cacheKey: AssetCacheKey
    let token: AssetCacheService.CacheToken
    let payload: Data
}

private struct SiblingIssuedAuthorityOperation {
    let cache: AssetDiskCache
    let cacheKey: AssetCacheKey
    let token: AssetCacheService.CacheToken
    let payload: Data
}

/// Ownership lifecycle coverage for the record-count quota. Kept separate
/// from the base suite to preserve its type-body lint budget.
extension AssetDiskCacheAuthorityRecordQuotaTests {
    @Test(
        """
        Count pressure from an unrelated cache miss never reclaims an open tombstone whose \
        owner session is still live. When the four-record high-water population is entirely \
        made of such live reservations, the next issuance is refused, while every original \
        token can still publish and be read back without becoming stale.
        """
    )
    func liveIssuancesSurvivePressureAndCanAllPublish() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(
                directory: directory,
                limits: limits(maxAuthorityRecordCount: 5)
            )
            var issued: [IssuedAuthorityOperation] = []

            for index in 0 ..< 5 {
                let cacheKey = try fixtures.key(String(format: "%05d", 1000 + index))
                let snapshot = try await cache.beginIssuance(for: cacheKey)
                issued.append(IssuedAuthorityOperation(
                    cacheKey: cacheKey,
                    token: token(from: snapshot),
                    payload: Data([UInt8(index)])
                ))
            }

            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: fixtures.key("02001"))
            }
            let recordCount = try recordNames(in: directory).count
            #expect(recordCount == 5)

            for operation in issued {
                let outcome = try await cache.set(
                    operation.cacheKey,
                    payload: operation.payload,
                    metadata: fixtures.metadata(
                        for: operation.cacheKey,
                        payload: operation.payload
                    ),
                    token: operation.token
                )
                #expect(outcome == .applied)
                let delivered = try await cache.get(operation.cacheKey)
                #expect(delivered?.payload == operation.payload)
            }
        }
    }

    @Test(
        """
        Terminal failure and cancellation explicitly settle their issued tombstones, making \
        both records reclaimable under later count pressure instead of leaving the owning \
        process's live session marker to pin them indefinitely.
        """
    )
    func terminalFailureAndCancellationSettleTombstones() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(
                directory: directory,
                limits: limits(maxAuthorityRecordCount: 5)
            )
            let failedKey = try fixtures.key("03001")
            let cancelledKey = try fixtures.key("03002")
            let failedSnapshot = try await cache.beginIssuance(for: failedKey)
            let cancelledSnapshot = try await cache.beginIssuance(for: cancelledKey)
            let failed = token(from: failedSnapshot)
            let cancelled = token(from: cancelledSnapshot)

            let failedBeforeSettlement = try await cache.currentKeyRecord(for: failedKey)
            let cancelledBeforeSettlement = try await cache.currentKeyRecord(for: cancelledKey)
            #expect(failedBeforeSettlement.openIssuanceOwnerID != nil)
            #expect(cancelledBeforeSettlement.openIssuanceOwnerID != nil)
            #expect(try await cache.settleIssuance(failedKey, token: failed) == .applied)
            #expect(try await cache.settleIssuance(cancelledKey, token: cancelled) == .applied)
            let failedAfterSettlement = try await cache.currentKeyRecord(for: failedKey)
            let cancelledAfterSettlement = try await cache.currentKeyRecord(for: cancelledKey)
            #expect(failedAfterSettlement.openIssuanceOwnerID == nil)
            #expect(cancelledAfterSettlement.openIssuanceOwnerID == nil)

            try seedSettledRecords(in: directory, indices: 0 ..< 3, firstRevision: 10)
            _ = try await cache.beginIssuance(for: fixtures.key("03200"))
            let names = try recordNames(in: directory)
            let failedRecordName = await cache.authorityRecordFilename(for: failedKey)
            let cancelledRecordName = await cache.authorityRecordFilename(for: cancelledKey)
            #expect(!names.contains(failedRecordName))
            #expect(!names.contains(cancelledRecordName))
        }
    }

    @Test(
        """
        An open tombstone whose durable owner marker exists but whose advisory lock is no \
        longer held models a crashed process. It is reclaimed without a wall-clock lease, \
        while an unexpired-but-slow live operation would remain protected by its lock.
        """
    )
    func orphanedOwnerIsReclaimedWithoutLeaseExpiry() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(
                directory: directory,
                limits: limits(maxAuthorityRecordCount: 5)
            )
            try await bootstrapRoot(cache, in: directory)
            var orphanMarkerNames: [String] = []

            for index in 0 ..< 5 {
                let ownerID = try AuthorityID.random()
                let markerName = CacheIssuanceOwner.markerName(for: ownerID)
                orphanMarkerNames.append(markerName)
                try Data().write(to: directory.appendingPathComponent(markerName))
                try seedRecord(
                    in: directory,
                    name: syntheticRecordName(index),
                    disposition: .pristine,
                    issued: authorityIdentifier(index),
                    revision: index + 1,
                    openIssuanceOwnerID: ownerID
                )
            }

            let recovered = try AssetDiskCache(
                directory: directory,
                limits: limits(maxAuthorityRecordCount: 5)
            )
            _ = try await recovered.beginIssuance(for: fixtures.key("04001"))
            let survivors = try recordNames(in: directory)
            #expect(survivors.count == 4)
            #expect(!survivors.contains(syntheticRecordName(0)))
            #expect(!survivors.contains(syntheticRecordName(1)))
            for markerName in orphanMarkerNames {
                #expect(!FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(markerName).path
                ))
            }
        }
    }

    @Test(
        """
        Records written before owner tracking decode as settled tombstones, so migration can \
        reclaim that legacy residue while preserving concurrent new-format live issuances \
        under the same count-pressure pass.
        """
    )
    func legacySettledTombstoneDoesNotConfuseLiveOwnerRecovery() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(
                directory: directory,
                limits: limits(maxAuthorityRecordCount: 5)
            )
            try await bootstrapRoot(cache, in: directory)
            let legacyName = syntheticRecordName(900)
            try seedRecord(
                in: directory,
                name: legacyName,
                disposition: .pristine,
                issued: authorityIdentifier(900),
                revision: 1
            )
            var json = try #require(
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: directory.appendingPathComponent(legacyName))
                ) as? [String: Any]
            )
            json.removeValue(forKey: "openIssuanceOwnerID")
            try JSONSerialization.data(withJSONObject: json).write(
                to: directory.appendingPathComponent(legacyName)
            )

            var live: [IssuedAuthorityOperation] = []
            for index in 0 ..< 4 {
                let cacheKey = try fixtures.key(String(format: "%05d", 5000 + index))
                let snapshot = try await cache.beginIssuance(for: cacheKey)
                live.append(IssuedAuthorityOperation(
                    cacheKey: cacheKey,
                    token: token(from: snapshot),
                    payload: Data([UInt8(index)])
                ))
            }
            _ = try await cache.beginIssuance(for: fixtures.key("05100"))
            let legacySurvived = try recordNames(in: directory).contains(legacyName)
            #expect(!legacySurvived)

            for operation in live {
                #expect(
                    try await cache.set(
                        operation.cacheKey,
                        payload: operation.payload,
                        metadata: fixtures.metadata(
                            for: operation.cacheKey,
                            payload: operation.payload
                        ),
                        token: operation.token
                    ) == .applied
                )
            }
        }
    }

    @Test(
        """
        Independently constructed cache instances sharing one root honor each other's live \
        owner sessions under count pressure: a sixth reservation is refused without deleting \
        either sibling's open tombstone, and every previously issued token can still publish.
        """
    )
    func siblingCacheSessionsKeepOpenAuthoritiesBoundedAndPublishable() async throws {
        try await fixtures.withScratchDirectory { directory in
            let limits = limits(maxAuthorityRecordCount: 5)
            let first = try AssetDiskCache(directory: directory, limits: limits)
            let second = try AssetDiskCache(directory: directory, limits: limits)
            var issued: [SiblingIssuedAuthorityOperation] = []

            for index in 0 ..< 5 {
                let cache = index.isMultiple(of: 2) ? first : second
                let cacheKey = try fixtures.key(String(format: "%05d", 6000 + index))
                let snapshot = try await cache.beginIssuance(for: cacheKey)
                issued.append(SiblingIssuedAuthorityOperation(
                    cache: cache,
                    cacheKey: cacheKey,
                    token: token(from: snapshot),
                    payload: Data([UInt8(index)])
                ))
            }

            await #expect(throws: AssetError.self) {
                _ = try await first.beginIssuance(for: fixtures.key("06100"))
            }

            for operation in issued {
                #expect(
                    try await operation.cache.set(
                        operation.cacheKey,
                        payload: operation.payload,
                        metadata: fixtures.metadata(
                            for: operation.cacheKey,
                            payload: operation.payload
                        ),
                        token: operation.token
                    ) == .applied
                )
            }
        }
    }
}
