@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Boundary cases for retiring-record recovery, isolated from the broader
/// restart suite to preserve the test source's lint budgets.
extension AssetDiskCacheAuthorityRecordQuotaTests {
    @Test(
        """
        A retiring record that names a present but unlocked session marker models an owner that \
        crashed after phase one. Startup probes the lock, settles the record, and rejects the \
        original token rather than mistaking the marker for a live owner.
        """
    )
    func unlockedRetiringOwnerMarkerIsReconciledAndFenced() async throws {
        try await fixtures.withScratchDirectory { directory in
            let limits = limits(maxAuthorityRecordCount: 8)
            let cache = try AssetDiskCache(directory: directory, limits: limits)
            try await bootstrapRoot(cache, in: directory)
            let cacheKey = try fixtures.key("07600")
            let authorityID = try AuthorityID.random()
            let ownerID = try AuthorityID.random()
            let markerName = CacheIssuanceOwner.markerName(for: ownerID)
            try Data().write(to: directory.appendingPathComponent(markerName))
            let recordName = await cache.authorityRecordFilename(for: cacheKey)
            let retiring = AssetDiskCache.KeyAuthorityRecord(
                issuedAuthorityID: authorityID,
                disposition: AssetDiskCache.KeyDisposition(
                    authorityID: authorityID,
                    kind: .retiring,
                    contentHash: nil
                ),
                transitionRevision: 1,
                openIssuanceOwnerID: ownerID
            )
            try JSONEncoder.assetCache().encode(retiring)
                .write(to: directory.appendingPathComponent(recordName))

            let restarted = try AssetDiskCache(directory: directory, limits: limits)
            _ = try await restarted.beginIssuance(for: fixtures.key("07601"))
            let settled = try await restarted.currentKeyRecord(for: cacheKey)
            #expect(settled.disposition.kind == .tombstone)
            #expect(settled.openIssuanceOwnerID == nil)

            let staleToken = AssetCacheService.CacheToken(
                generation: 0,
                issuance: 0,
                clearGeneration: 0,
                durableClearEpoch: 0,
                diskAuthorityID: authorityID
            )
            let payload = Data([7, 6])
            #expect(
                try await restarted.set(
                    cacheKey,
                    payload: payload,
                    metadata: fixtures.metadata(for: cacheKey, payload: payload),
                    token: staleToken
                ) == .stale
            )
        }
    }

    @Test(
        """
        A delayed phase two for retired authority A preserves a newer live issuance B that has \
        already inherited A's retiring disposition. B remains owner-stamped and can publish \
        after A's `retiring -> tombstone` completion.
        """
    )
    func phaseTwoPreservesNewerLiveIssuanceOwner() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(
                directory: directory,
                limits: limits(maxAuthorityRecordCount: 8)
            )
            let retired = try await phaseOneRetraction(on: cache, rawCardCode: "07700")
            let newerSnapshot = try await cache.beginIssuance(for: retired.cacheKey)
            let newerToken = token(from: newerSnapshot)

            try await cache.completeRetraction(retired.cacheKey, token: retired.token)
            let afterPhaseTwo = try await cache.currentKeyRecord(for: retired.cacheKey)
            #expect(afterPhaseTwo.disposition.kind == .tombstone)
            #expect(afterPhaseTwo.issuedAuthorityID == newerSnapshot.authorityID)
            #expect(afterPhaseTwo.openIssuanceOwnerID != nil)

            let replacement = Data([7, 7])
            #expect(
                try await cache.set(
                    retired.cacheKey,
                    payload: replacement,
                    metadata: fixtures.metadata(for: retired.cacheKey, payload: replacement),
                    token: newerToken
                ) == .applied
            )
        }
    }

    @Test(
        """
        Startup retiring reconciliation ignores an unparseable authority record it cannot prove \
        is retiring, preserving removeAll's existing ability to clear that corrupt cache root \
        rather than permanently turning a write-only fail-closed record into a root failure.
        """
    )
    func corruptAuthorityRecordDoesNotBlockClear() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(
                directory: directory,
                limits: limits(maxAuthorityRecordCount: 8)
            )
            try await bootstrapRoot(cache, in: directory)
            let corruptName = String(repeating: "a", count: 64)
                + AssetDiskCache.authorityRecordFilenameSuffix
            try Data("not json".utf8).write(to: directory.appendingPathComponent(corruptName))

            let restarted = try AssetDiskCache(
                directory: directory,
                limits: limits(maxAuthorityRecordCount: 8)
            )
            try await restarted.removeAll()
            #expect(!FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(corruptName).path
            ))
        }
    }

    @Test(
        """
        An unverifiable owner marker on a retiring record explicitly blocks new write admission \
        without blocking removeAll's durable epoch fence. The clear preserves the unverified \
        marker rather than risking a live foreign session, never follows its symlink target, then \
        permits a fresh owner session.
        """
    )
    func unverifiableRetiringOwnerBlocksWritesButNotClear() async throws {
        try await fixtures.withScratchDirectory { directory in
            let limits = limits(maxAuthorityRecordCount: 8)
            let cache = try AssetDiskCache(directory: directory, limits: limits)
            try await bootstrapRoot(cache, in: directory)
            let cacheKey = try fixtures.key("07800")
            let authorityID = try AuthorityID.random()
            let ownerID = try AuthorityID.random()
            let markerName = CacheIssuanceOwner.markerName(for: ownerID)
            let target = directory.deletingLastPathComponent()
                .appendingPathComponent("owner-target-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: target) }
            try Data([7]).write(to: target)
            try FileManager.default.createSymbolicLink(
                at: directory.appendingPathComponent(markerName),
                withDestinationURL: target
            )
            let recordName = await cache.authorityRecordFilename(for: cacheKey)
            let retiring = AssetDiskCache.KeyAuthorityRecord(
                issuedAuthorityID: authorityID,
                disposition: AssetDiskCache.KeyDisposition(
                    authorityID: authorityID,
                    kind: .retiring,
                    contentHash: nil
                ),
                transitionRevision: 1,
                openIssuanceOwnerID: ownerID
            )
            try JSONEncoder.assetCache().encode(retiring)
                .write(to: directory.appendingPathComponent(recordName))

            let restarted = try AssetDiskCache(directory: directory, limits: limits)
            await #expect(throws: AssetError.self) {
                _ = try await restarted.beginIssuance(for: fixtures.key("07801"))
            }
            try await restarted.removeAll()
            #expect(FileManager.default.fileExists(atPath: target.path))
            #expect(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(markerName).path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(recordName).path
            ))
            _ = try await restarted.beginIssuance(for: fixtures.key("07801"))
        }
    }

    @Test(
        """
        A clear from one cache instance preserves another live session marker. The sibling can \
        issue and publish fresh post-clear work under that marker, while its pre-clear token is \
        durably fenced by the new epoch and cannot publish.
        """
    )
    func clearPreservesLiveSiblingSessionForPostClearIssuance() async throws {
        try await fixtures.withScratchDirectory { directory in
            let limits = limits(maxAuthorityRecordCount: 8)
            let owner = try AssetDiskCache(directory: directory, limits: limits)
            let preClearKey = try fixtures.key("07900")
            let preClearSnapshot = try await owner.beginIssuance(for: preClearKey)
            let preClearToken = token(from: preClearSnapshot)
            let ownerID = try #require(
                try await owner.currentKeyRecord(for: preClearKey).openIssuanceOwnerID
            )
            let markerName = CacheIssuanceOwner.markerName(for: ownerID)

            let clearer = try AssetDiskCache(directory: directory, limits: limits)
            try await clearer.removeAll()
            #expect(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(markerName).path
            ))

            let postClearKey = try fixtures.key("07901")
            let postClearSnapshot = try await owner.beginIssuance(for: postClearKey)
            #expect(postClearSnapshot.clearEpoch > preClearSnapshot.clearEpoch)
            let postClearToken = token(from: postClearSnapshot)
            let postClearPayload = Data([7, 9])
            #expect(
                try await owner.set(
                    postClearKey,
                    payload: postClearPayload,
                    metadata: fixtures.metadata(for: postClearKey, payload: postClearPayload),
                    token: postClearToken
                ) == .applied
            )

            let stalePayload = Data([7, 8])
            #expect(
                try await owner.set(
                    preClearKey,
                    payload: stalePayload,
                    metadata: fixtures.metadata(for: preClearKey, payload: stalePayload),
                    token: preClearToken
                ) == .stale
            )
        }
    }
}
