@testable import ArkhamHorrorShared
import Foundation
import Testing

struct RetiringAuthorityOperation {
    let cacheKey: AssetCacheKey
    let token: AssetCacheService.CacheToken
    let payload: Data
}

/// Crash recovery coverage for phase-one retractions. Kept separate from
/// the base quota suite to preserve its file and type-body lint budgets.
extension AssetDiskCacheAuthorityRecordQuotaTests {
    func phaseOneRetraction(
        on cache: AssetDiskCache,
        rawCardCode: String
    ) async throws -> RetiringAuthorityOperation {
        let cacheKey = try fixtures.key(rawCardCode)
        let snapshot = try await cache.beginIssuance(for: cacheKey)
        let token = token(from: snapshot)
        let payload = Data(rawCardCode.utf8)
        _ = try await cache.set(
            cacheKey,
            payload: payload,
            metadata: fixtures.metadata(for: cacheKey, payload: payload),
            token: token
        )
        _ = try await cache.beginRetraction(cacheKey, token: token)
        return RetiringAuthorityOperation(cacheKey: cacheKey, token: token, payload: payload)
    }

    @Test(
        """
        Four ownerless records left at durable phase one by a crashed process are completed on \
        the next startup before quota admission runs. A fifth issuance succeeds under a \
        four-record cap, and every pre-crash token remains unable to publish.
        """
    )
    func orphanedPhaseOneRetractionsRecoverBeforeQuotaAdmission() async throws {
        try await fixtures.withScratchDirectory { directory in
            var orphaned: [RetiringAuthorityOperation] = []
            do {
                let original = try AssetDiskCache(
                    directory: directory,
                    limits: limits(maxAuthorityRecordCount: 8)
                )
                for index in 0 ..< 4 {
                    try await orphaned.append(phaseOneRetraction(
                        on: original,
                        rawCardCode: String(format: "%05d", 7000 + index)
                    ))
                }
            }

            let restarted = try AssetDiskCache(
                directory: directory,
                limits: limits(maxAuthorityRecordCount: 4)
            )
            let fifthKey = try fixtures.key("07100")
            let fifth = try await restarted.beginIssuance(for: fifthKey)
            #expect(fifth.authorityID != .pristine)

            for operation in orphaned {
                let outcome = try await restarted.set(
                    operation.cacheKey,
                    payload: operation.payload,
                    metadata: fixtures.metadata(
                        for: operation.cacheKey,
                        payload: operation.payload
                    ),
                    token: operation.token
                )
                #expect(outcome == .stale)
            }
        }
    }

    @Test(
        """
        A retiring record owned by a live sibling cache session is preserved by both startup \
        and quota reconciliation, while settled tombstones around it remain reclaimable.
        """
    )
    func liveRetiringOwnerIsNeverReclaimed() async throws {
        try await fixtures.withScratchDirectory { directory in
            let limits = limits(maxAuthorityRecordCount: 4)
            let owner = try AssetDiskCache(directory: directory, limits: limits)
            let liveKey = try fixtures.key("07200")
            let snapshot = try await owner.beginIssuance(for: liveKey)
            let initial = try await owner.currentKeyRecord(for: liveKey)
            let ownerID = try #require(initial.openIssuanceOwnerID)
            let retiring = AssetDiskCache.KeyAuthorityRecord(
                issuedAuthorityID: snapshot.authorityID,
                disposition: AssetDiskCache.KeyDisposition(
                    authorityID: snapshot.authorityID,
                    kind: .retiring,
                    contentHash: nil
                ),
                transitionRevision: initial.transitionRevision + 1,
                openIssuanceOwnerID: ownerID
            )
            let recordName = await owner.authorityRecordFilename(for: liveKey)
            try JSONEncoder.assetCache().encode(retiring)
                .write(to: directory.appendingPathComponent(recordName))
            try seedSettledRecords(in: directory, indices: 0 ..< 3, firstRevision: 10)

            let sibling = try AssetDiskCache(directory: directory, limits: limits)
            _ = try await sibling.beginIssuance(for: fixtures.key("07201"))

            let retained = try await sibling.currentKeyRecord(for: liveKey)
            #expect(retained.disposition.kind == .retiring)
            #expect(retained.openIssuanceOwnerID == ownerID)
        }
    }

    @Test(
        """
        A phase-two metadata-removal failure leaves a retryable retiring record rather than a \
        permanently-live one. A restarted reconciler surfaces the injected retry failure, then \
        completes the same record once I/O recovers.
        """
    )
    func phaseTwoFailureIsRetryableByStartupReconciliation() async throws {
        try await fixtures.withScratchDirectory { directory in
            let limits = limits(maxAuthorityRecordCount: 8)
            let original = try AssetDiskCache(directory: directory, limits: limits)
            let operation = try await phaseOneRetraction(on: original, rawCardCode: "07300")
            let metadataName = await original.metadataFilename(for: operation.cacheKey)
            await original.directoryAccess.installFaultInjection(
                failRemoveSuffixes: [metadataName]
            )
            await #expect(throws: AssetError.self) {
                try await original.completeRetraction(
                    operation.cacheKey,
                    token: operation.token
                )
            }

            let restarted = try AssetDiskCache(directory: directory, limits: limits)
            await restarted.directoryAccess.installFaultInjection(
                failRemoveSuffixes: [metadataName]
            )
            await #expect(throws: AssetError.self) {
                _ = try await restarted.beginIssuance(for: fixtures.key("07301"))
            }
            await restarted.directoryAccess.installFaultInjection()

            _ = try await restarted.beginIssuance(for: fixtures.key("07301"))
            let recovered = try await restarted.currentKeyRecord(for: operation.cacheKey)
            #expect(recovered.disposition.kind == .tombstone)
            #expect(recovered.openIssuanceOwnerID == nil)
        }
    }

    @Test(
        """
        Concurrent cache instances serialize orphaned phase-two completion through the shared \
        root lock: they leave exactly one legal `retiring -> tombstone` transition, then both \
        continue issuing independent fresh authorities.
        """
    )
    func concurrentReconcilersFinalizeAnOrphanExactlyOnce() async throws {
        try await fixtures.withScratchDirectory { directory in
            let limits = limits(maxAuthorityRecordCount: 8)
            let original = try AssetDiskCache(directory: directory, limits: limits)
            let operation = try await phaseOneRetraction(on: original, rawCardCode: "07400")
            let retiring = try await original.currentKeyRecord(for: operation.cacheKey)
            #expect(retiring.disposition.kind == .retiring)

            let first = try AssetDiskCache(directory: directory, limits: limits)
            let second = try AssetDiskCache(directory: directory, limits: limits)
            async let firstIssuance = first.beginIssuance(for: fixtures.key("07401"))
            async let secondIssuance = second.beginIssuance(for: fixtures.key("07402"))
            _ = try await (firstIssuance, secondIssuance)

            let settled = try await first.currentKeyRecord(for: operation.cacheKey)
            #expect(settled.disposition.kind == .tombstone)
            #expect(settled.transitionRevision == retiring.transitionRevision + 1)
        }
    }

    @Test(
        """
        A legacy owner-less retiring record is unambiguously an orphan for this format and is \
        completed during startup reconciliation rather than being permanently counted as live.
        """
    )
    func legacyOwnerlessRetiringRecordRecoversAtStartup() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(
                directory: directory,
                limits: limits(maxAuthorityRecordCount: 8)
            )
            try await bootstrapRoot(cache, in: directory)
            let cacheKey = try fixtures.key("07500")
            let authorityID = try AuthorityID.random()
            let recordName = await cache.authorityRecordFilename(for: cacheKey)
            let legacy = AssetDiskCache.KeyAuthorityRecord(
                issuedAuthorityID: authorityID,
                disposition: AssetDiskCache.KeyDisposition(
                    authorityID: authorityID,
                    kind: .retiring,
                    contentHash: nil
                ),
                transitionRevision: 1
            )
            try JSONEncoder.assetCache().encode(legacy)
                .write(to: directory.appendingPathComponent(recordName))

            let restarted = try AssetDiskCache(
                directory: directory,
                limits: limits(maxAuthorityRecordCount: 8)
            )
            _ = try await restarted.beginIssuance(for: fixtures.key("07501"))
            let recovered = try await restarted.currentKeyRecord(for: cacheKey)
            #expect(recovered.disposition.kind == .tombstone)
            #expect(recovered.openIssuanceOwnerID == nil)
        }
    }
}
