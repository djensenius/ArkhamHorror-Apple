@testable import ArkhamHorrorShared
import Foundation
import Testing

/// The end-to-end half of the authority-record count quota: real
/// issuance churn against the UNMODIFIED production limits.
///
/// Reuses `AssetDiskCacheAuthorityRecordQuotaTests`' fixture helpers by
/// composition; that file is also where the mechanism's unit-scale
/// behaviour -- boundaries, reclaim ordering, and the fail-closed
/// conditions -- is pinned.
@Suite("AssetDiskCache authority record quota under production churn")
struct AssetDiskCacheRecordQuotaChurnTests {
    private let quota = AssetDiskCacheAuthorityRecordQuotaTests()
    private let fixtures = AssetDiskCacheAuthorityIssuanceTests()

    @Test(
        """
        Thousands of distinct transport-failure keys -- issued, never published -- churned \
        against AssetCacheLimits.production UNMODIFIED do not grow this cache's durable \
        record population without bound: reclaim engages the moment the production \
        high-water mark is crossed and holds the population under the production cap \
        thereafter. Restarting over the same directory keeps that bound, and a key whose \
        record was reclaimed simply issues a brand-new, uncollided identifier.
        """,
        .timeLimit(.minutes(2))
    )
    func productionDefaultsBoundIssuanceOnlyChurn() async throws {
        try await fixtures.withScratchDirectory { directory in
            let limits = AssetCacheLimits.production
            let highWater = limits.highWaterMarkAuthorityRecordCount
            #expect(highWater == 18000)
            #expect(limits.lowWaterMarkAuthorityRecordCount == 15000)
            let cache = try AssetDiskCache(directory: directory, limits: limits)
            try await quota.bootstrapRoot(cache, in: directory)

            // The first (highWater - 40) transport-failure keys are
            // written byte-for-byte in the shape issuance itself commits
            // for a never-published key, purely so this test spends its
            // CI budget on the boundary behaviour rather than on
            // re-proving that eighteen thousand identical issuances each
            // write one file. Every issuance that actually matters --
            // the ones that approach, cross, and then live past the
            // production high-water mark -- goes through the real
            // `beginIssuance` path below.
            try quota.seedSettledRecords(in: directory, indices: 0 ..< (highWater - 40))
            var issuedIdentifiers: Set<AuthorityID> = []
            var peakCount = 0
            for index in 0 ..< 120 {
                let snapshot = try await cache.beginIssuance(
                    for: fixtures.key(String(format: "%05d", 10000 + index))
                )
                #expect(issuedIdentifiers.insert(snapshot.authorityID).inserted)
                let count = try quota.recordNames(in: directory).count
                peakCount = max(peakCount, count)
            }

            let afterChurn = try quota.recordNames(in: directory).count
            #expect(peakCount <= limits.maxAuthorityRecordCount)
            #expect(
                afterChurn < highWater,
                "Reclaim must have engaged and pulled the population back under the mark"
            )
            #expect(
                afterChurn >= limits.lowWaterMarkAuthorityRecordCount,
                "Reclaim stops at the low-water mark rather than emptying the cache"
            )

            // A restart over the same directory sees the same bounded,
            // fully accounted population, and a key whose record was
            // reclaimed issues a fresh identifier that collides with
            // nothing previously issued.
            let restarted = try AssetDiskCache(directory: directory, limits: limits)
            let reissued = try await restarted.beginIssuance(
                for: fixtures.key(String(format: "%05d", 10000))
            )
            #expect(reissued.authorityID != AuthorityID.pristine)
            #expect(issuedIdentifiers.contains(reissued.authorityID) == false)
            let afterRestart = try quota.recordNames(in: directory).count
            #expect(afterRestart <= limits.maxAuthorityRecordCount)
        }
    }
}
