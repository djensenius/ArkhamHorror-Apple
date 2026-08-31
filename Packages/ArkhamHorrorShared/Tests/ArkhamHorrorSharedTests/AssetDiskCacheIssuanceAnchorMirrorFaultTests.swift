@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Split out of `AssetDiskCacheIssuanceAnchorTests.swift` purely to stay
/// under this package's `file_length` convention -- both files together
/// cover this review round's finding #1 (see that file's own type-level
/// doc comment for the full reasoning); this file specifically covers
/// finding #1's own exact fault window: only the mirror's own write
/// failing during `commitAuthorityRecordLocked(_:for:)`, which -- since
/// the anchor is always written first and lands successfully -- leaves
/// the anchor durably ahead of an otherwise internally *consistent*
/// primary/mirror pair, for both a fresh content publish and a
/// retiring/tombstone transition. Reuses `AssetDiskCacheIssuanceAnchorTests.swift`'s
/// own `anchorURL`/`publishInitialContent` helpers (both non-`private`
/// on the shared `extension AssetDiskCacheTests` for exactly this
/// reason) and `AssetDiskCacheAuthorityRecordMirrorTests.swift`'s
/// `primaryURL`/`mirrorURL`/`mirrorTestToken`/`mirrorTestMetadata`.
extension AssetDiskCacheTests {
    /// Both this same instance and a fresh sibling/restart instance must
    /// fail closed identically once the anchor written by a failed
    /// commit is durably ahead of a still-consistent-but-stale
    /// primary/mirror pair -- shared by both tests below purely to keep
    /// each test's own body under this package's `function_body_length`
    /// convention.
    private func assertBothInstancesFailClosed(
        directory: URL,
        cache: AssetDiskCache,
        cacheKey: AssetCacheKey
    ) async throws {
        await #expect(throws: AssetError.self) {
            _ = try await cache.currentKeyDisposition(for: cacheKey)
        }
        await cache.directoryAccess.installFaultInjection()
        let siblingCache = try AssetDiskCache(directory: directory, limits: smallLimits())
        await #expect(throws: AssetError.self) {
            _ = try await siblingCache.currentKeyDisposition(for: cacheKey)
        }
    }

    /// `JSONEncoder.assetCache()` (no `.sortedKeys`) does not guarantee
    /// identical key ordering across two independent `encode(_:)` calls
    /// for the same logical value -- only decoded-record equality
    /// (exactly what production's own `KeyAuthorityRecord.Equatable`
    /// conformance, and every comparison
    /// `currentAuthorityRecordLocked(for:)` itself performs, actually
    /// relies on) is a meaningful invariant to assert on two
    /// independently-written copies here.
    private func assertDecodedAuthorityRecordsMatch(_ lhs: Data, _ rhs: Data) throws {
        #expect(
            try JSONDecoder.assetCache().decode(AssetDiskCache.KeyAuthorityRecord.self, from: lhs)
                == JSONDecoder.assetCache().decode(
                    AssetDiskCache.KeyAuthorityRecord.self,
                    from: rhs
                )
        )
    }

    /// Reserves a fresh revalidation ticket -- which itself durably
    /// commits via `issueTicketLocked`, so it must happen *before* any
    /// fault is installed and *before* the "older" snapshot below is
    /// captured, or it would either trip the fault itself or make the
    /// captured snapshot stale by the time the fault takes effect --
    /// then captures and cross-checks the still-agreeing primary/mirror
    /// pair exactly as it stood immediately beforehand.
    private func reserveRevalidationAndCaptureAgreeingPair(
        cache: AssetDiskCache,
        directory: URL,
        cacheKey: AssetCacheKey,
        issuance: AssetDiskCache.IssuanceSnapshot,
        metadata: AssetCacheMetadata
    ) async throws -> (revalidation: AssetDiskCache.IssuanceSnapshot, olderPrimary: Data) {
        let revalidation = try #require(
            try await cache.beginRevalidationIssuance(
                for: cacheKey,
                expectedClearEpoch: issuance.clearEpoch,
                expectedAppliedTicket: issuance.writeGeneration,
                expectedContentHash: metadata.payloadSHA256Hex
            )
        )
        let olderPrimary = try await Data(
            contentsOf: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
        )
        let olderMirror = try await Data(
            contentsOf: mirrorURL(directory: directory, cache: cache, cacheKey: cacheKey)
        )
        try assertDecodedAuthorityRecordsMatch(olderPrimary, olderMirror)
        return (revalidation, olderPrimary)
    }

    @Test(
        """
        Finding #1's exact fault window on a fresh content publish: only the mirror's own \
        write fails (the anchor's own write -- always first -- still lands), leaving primary \
        and mirror both durably stuck at the same, older, internally-consistent value. Without \
        the anchor, an agreeing primary/mirror pair would be blindly trusted; with it, a \
        reconciled result strictly behind its own anchor must fail closed
        """
    )
    func mirrorWriteFailureLeavesAnchorAheadOfConsistentPairForContentUpdate() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            let (issuance, metadata) = try await publishInitialContent(
                cache: cache,
                cacheKey: cacheKey,
                payload: payload
            )
            let (revalidation, olderPrimary) = try await reserveRevalidationAndCaptureAgreeingPair(
                cache: cache,
                directory: directory,
                cacheKey: cacheKey,
                issuance: issuance,
                metadata: metadata
            )

            // Fails only the mirror's own write -- the anchor (always
            // written first) still durably lands the newer value, but
            // this failure propagates straight out of
            // `commitAuthorityRecordLocked` before the primary's own
            // write is ever even attempted, leaving primary and mirror
            // both stuck at the exact same older value: an internally
            // *agreeing* pair that is nonetheless stale.
            let mirrorName = await cache.authorityRecordMirrorFilename(for: cacheKey)
            await cache.directoryAccess.installFaultInjection(failSuffixes: [mirrorName])

            let refreshedPayload = Data([9, 8, 7, 6, 5])
            let refreshedToken = mirrorTestToken(from: revalidation)
            let refreshedMetadata = mirrorTestMetadata(
                for: cacheKey,
                payload: refreshedPayload,
                issuance: revalidation
            )
            await #expect(throws: AssetError.self) {
                try await cache.set(
                    cacheKey,
                    payload: refreshedPayload,
                    metadata: refreshedMetadata,
                    token: refreshedToken
                )
            }

            let currentPrimary = try await Data(
                contentsOf: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )
            #expect(
                currentPrimary == olderPrimary,
                "The primary's own write must never even have been attempted"
            )

            try await assertBothInstancesFailClosed(
                directory: directory,
                cache: cache,
                cacheKey: cacheKey
            )
        }
    }

    @Test(
        """
        Finding #1's exact fault window on a retiring/tombstone transition: only the mirror's \
        own write fails during a retraction's `.retiring` commit, leaving primary and mirror \
        both durably stuck at the prior, agreeing `.content` disposition while the anchor \
        alone has already advanced -- the reconciled result must still fail closed rather than \
        silently continuing to serve the stale, pre-retraction content
        """
    )
    func mirrorWriteFailureLeavesAnchorAheadOfConsistentPairForRetiringTransition() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            let (issuance, _) = try await publishInitialContent(
                cache: cache,
                cacheKey: cacheKey,
                payload: payload
            )
            let token = mirrorTestToken(from: issuance)

            let olderPrimary = try await Data(
                contentsOf: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )

            let mirrorName = await cache.authorityRecordMirrorFilename(for: cacheKey)
            await cache.directoryAccess.installFaultInjection(failSuffixes: [mirrorName])

            await #expect(throws: AssetError.self) {
                try await cache.removeIfApplied(cacheKey, token: token)
            }

            #expect(
                try await Data(
                    contentsOf: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
                ) == olderPrimary,
                "The primary's own write must never even have been attempted"
            )

            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyDisposition(for: cacheKey)
            }
            await cache.directoryAccess.installFaultInjection()
            // `get(_:)` itself never throws for a fail-closed disposition
            // read (see its own doc comment: a corrupt/untrustworthy
            // entry is quarantined and reported as an ordinary miss,
            // exactly like any other invalid entry) -- but it must never
            // silently continue serving the stale, pre-retraction
            // content either.
            let hit = try await cache.get(cacheKey)
            #expect(hit == nil)
            let siblingCache = try AssetDiskCache(directory: directory, limits: smallLimits())
            await #expect(throws: AssetError.self) {
                _ = try await siblingCache.currentKeyDisposition(for: cacheKey)
            }
        }
    }
}
