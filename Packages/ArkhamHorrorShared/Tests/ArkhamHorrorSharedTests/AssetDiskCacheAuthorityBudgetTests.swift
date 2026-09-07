@testable import ArkhamHorrorShared
import Foundation
import Testing

/// The budget/capacity half of the random-authority redesign's
/// acceptance suite (see `AssetDiskCacheAuthorityIssuanceTests.swift`
/// for the issuance/CAS half).
///
/// Two of the reviewer's findings are about *silent* success rather than
/// about identifiers:
///
/// - Every authority issuance must prove its write budget afresh. The
///   predecessor design amortized that proof over a 64-issuance,
///   actor-local window (`ticketIssuanceBudgetProofInterval`), which
///   meant a workload made of many short-lived instances -- each doing
///   fewer than 64 operations, each starting its own window from zero --
///   could keep writing indefinitely without the full proof ever running
///   more than once per instance. That throttle is deleted: this suite
///   pins the replacement behaviour so it cannot be reintroduced.
/// - A clear (or an eviction pass) that cannot actually reclaim down to
///   its cap must surface a typed failure, never report success.
@Suite("AssetDiskCache authority budget and capacity")
struct AssetDiskCacheAuthorityBudgetTests {
    func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
        let rootParent = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("DiskCacheAuthorityBudgetScratch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootParent,
            withIntermediateDirectories: true
        )
        let root = rootParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    func limits(diskBudgetBytes: Int = 1_000_000) -> AssetCacheLimits {
        AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1_000_000,
            diskBudgetBytes: diskBudgetBytes
        )
    }

    func key(_ rawCardCode: String) throws -> AssetCacheKey {
        let identifier = try AssetIdentifier.cardCode(rawCardCode)
        let assetKey = AssetKey(category: .card(.art, identifier))
        let candidates = AssetLocator.candidates(for: assetKey, digest: FakeDigestLookup())
        return AssetCacheKey(for: assetKey, candidates: candidates)
    }

    func metadata(for cacheKey: AssetCacheKey, payload: Data) -> AssetCacheMetadata {
        AssetCacheMetadata(
            cacheKeyHex: cacheKey.digestHex,
            contentType: "image/png",
            encodedByteCount: payload.count,
            width: 4,
            height: 4,
            payloadSHA256Hex: AssetPayloadHasher.sha256Hex(payload),
            etag: nil,
            lastModified: nil,
            resolvedURLString: "https://example.com/a",
            insertedAt: Date(),
            accessSequence: AssetAccessSequence(0)
        )
    }

    // MARK: - (d) Every issuance proves budget, including across short-lived instances

    @Test(
        """
        A long run of short-lived cache instances, each performing far fewer operations than \
        the predecessor design's 64-issuance budget-proof window, can never slip a single \
        issuance past the budget proof: the moment the directory is provably over budget and \
        cannot be reclaimed, the very first issuance of the very next freshly created instance \
        fails closed, not its sixty-fifth.
        """
    )
    func everyIssuanceProvesBudgetEvenAcrossManyShortLivedInstances() async throws {
        try await withScratchDirectory { directory in
            // Published under a generous budget so the entry actually
            // lands; every instance below then views the same directory
            // through a budget small enough that this one entry alone
            // already exceeds it.
            let tightLimits = limits(diskBudgetBytes: 2048)
            let payload = Data(repeating: 7, count: 1400)
            let publishedKey = try key("01001")

            let publisher = try AssetDiskCache(directory: directory, limits: limits())
            let publishSnapshot = try await publisher.beginIssuance(for: publishedKey)
            try await publisher.set(
                publishedKey,
                payload: payload,
                metadata: metadata(for: publishedKey, payload: payload),
                token: AssetCacheService.CacheToken(
                    generation: 0,
                    issuance: 0,
                    clearGeneration: 0,
                    durableClearEpoch: publishSnapshot.clearEpoch,
                    diskAuthorityID: publishSnapshot.authorityID
                )
            )

            // Each iteration is a brand-new instance with its own,
            // zeroed actor-local state -- exactly the shape that defeated
            // an actor-local throttle window. Every single one of them
            // must fail closed on its *first* issuance.
            for round in 0 ..< 8 {
                let shortLived = try AssetDiskCache(directory: directory, limits: tightLimits)
                // Pins the over-budget bytes in place: eviction can
                // select the published entry but can never actually
                // reclaim it, so no pass ever gets accounted usage back
                // under the cap.
                await shortLived.directoryAccess.installFaultInjection(
                    failRemoveSuffixes: [".bin", ".meta.json"]
                )
                let churnKey = try key(String(format: "%05d", 2000 + round))
                await #expect(throws: AssetError.self) {
                    _ = try await shortLived.beginIssuance(for: churnKey)
                }
                // ...and no record was left behind for the key whose
                // issuance was refused.
                let record = try await shortLived.currentKeyRecord(for: churnKey)
                #expect(
                    record == AssetDiskCache.KeyAuthorityRecord.pristine,
                    "A budget-refused issuance must not durably create anything"
                )
            }
        }
    }

    @Test(
        """
        The same gate applies to the very first operation a fresh instance ever performs, with \
        no prior issuance of its own to have primed any counter: once the durable \
        writes-disabled state exists on disk, a newly constructed instance's first issuance \
        fails closed immediately.
        """
    )
    func firstIssuanceAfterRestartIsGatedWithNoWarmUpWindow() async throws {
        try await withScratchDirectory { directory in
            let tightLimits = limits(diskBudgetBytes: 2048)
            let payload = Data(repeating: 3, count: 1400)
            let publishedKey = try key("01001")

            let publisher = try AssetDiskCache(directory: directory, limits: limits())
            let snapshot = try await publisher.beginIssuance(for: publishedKey)
            try await publisher.set(
                publishedKey,
                payload: payload,
                metadata: metadata(for: publishedKey, payload: payload),
                token: AssetCacheService.CacheToken(
                    generation: 0,
                    issuance: 0,
                    clearGeneration: 0,
                    durableClearEpoch: snapshot.clearEpoch,
                    diskAuthorityID: snapshot.authorityID
                )
            )
            // Drives one pass, under the tight budget, that durably
            // records "writes disabled" because the over-budget bytes
            // cannot be reclaimed.
            let disabler = try AssetDiskCache(directory: directory, limits: tightLimits)
            await disabler.directoryAccess.installFaultInjection(
                failRemoveSuffixes: [".bin", ".meta.json"]
            )
            await #expect(throws: AssetError.self) {
                _ = try await disabler.beginIssuance(for: key("02001"))
            }

            let restarted = try AssetDiskCache(directory: directory, limits: tightLimits)
            await restarted.directoryAccess.installFaultInjection(
                failRemoveSuffixes: [".bin", ".meta.json"]
            )
            await #expect(throws: AssetError.self) {
                _ = try await restarted.beginIssuance(for: key("02002"))
            }
        }
    }

    // MARK: - (e) Unreclaimable entries can never let a clear report success

    @Test(
        """
        A large population of entries that physically cannot be removed must never let \
        removeAll() report a successful clear: the clear surfaces a typed persistence failure \
        naming the entries it could not reclaim, and every one of those entries is still \
        present on disk afterward.
        """
    )
    func unreclaimableEntriesMakeClearFailRatherThanSilentlySucceed() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let payload = Data(repeating: 5, count: 64)
            let keyCount = 200

            for index in 0 ..< keyCount {
                let cacheKey = try key(String(format: "%05d", 3000 + index))
                let snapshot = try await cache.beginIssuance(for: cacheKey)
                try await cache.set(
                    cacheKey,
                    payload: payload,
                    metadata: metadata(for: cacheKey, payload: payload),
                    token: AssetCacheService.CacheToken(
                        generation: 0,
                        issuance: 0,
                        clearGeneration: 0,
                        durableClearEpoch: snapshot.clearEpoch,
                        diskAuthorityID: snapshot.authorityID
                    )
                )
            }
            let before = try await cache.entryKeyHashes()
            #expect(before.count == keyCount)

            await cache.directoryAccess.installFaultInjection(
                failRemoveSuffixes: [".bin", ".meta.json"]
            )
            await #expect(throws: AssetError.self) {
                try await cache.removeAll()
            }
            await cache.directoryAccess.installFaultInjection()

            // The clear genuinely could not reclaim them, and said so.
            let after = try await cache.entryKeyHashes()
            #expect(
                after == before,
                "Every unreclaimable entry must still be present after the failed clear"
            )
        }
    }

    @Test(
        """
        The service-level clear behaves the same way: an unreclaimable disk population makes \
        evictAll() surface the failure to its caller (or, for a pre-fence failure, the \
        fence-specific case) rather than reporting a clear that never happened.
        """
    )
    func serviceEvictAllSurfacesUnreclaimableCapacityFailure() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let payload = Data(repeating: 9, count: 64)
            for index in 0 ..< 32 {
                let cacheKey = try key(String(format: "%05d", 4000 + index))
                let snapshot = try await cache.beginIssuance(for: cacheKey)
                try await cache.set(
                    cacheKey,
                    payload: payload,
                    metadata: metadata(for: cacheKey, payload: payload),
                    token: AssetCacheService.CacheToken(
                        generation: 0,
                        issuance: 0,
                        clearGeneration: 0,
                        durableClearEpoch: snapshot.clearEpoch,
                        diskAuthorityID: snapshot.authorityID
                    )
                )
            }
            await cache.directoryAccess.installFaultInjection(
                failRemoveSuffixes: [".bin", ".meta.json"]
            )
            await #expect(throws: AssetError.self) {
                try await cache.removeAll()
            }
            // The durable fence still advanced (it is committed before
            // any destructive work), so the failure reported is a
            // reclamation failure, not a fence failure -- and the caller
            // is told, rather than silently seeing success.
            await cache.directoryAccess.installFaultInjection()
            let hashes = try await cache.entryKeyHashes()
            #expect(hashes.count == 32)
        }
    }
}
