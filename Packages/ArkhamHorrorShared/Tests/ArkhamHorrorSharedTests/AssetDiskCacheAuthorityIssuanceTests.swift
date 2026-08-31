@testable import ArkhamHorrorShared
import Foundation
import Testing

/// The redesign's own acceptance suite: replays, against the single
/// canonical ``AssetDiskCache/KeyAuthorityRecord`` file, each of the
/// exact scenarios the predecessor ticket/floor/anchor/mirror design was
/// rejected for failing to close.
///
/// The whole argument for this design is that a *fresh 128-bit CSPRNG
/// identifier cannot collide with any identifier some other operation
/// might still be holding*, regardless of what durable state was lost
/// first. That single property is what deletes the global ticket
/// sequence, the per-key usage floor index, the issuance anchor, and the
/// record mirror all at once — so the tests here attack it directly:
/// destroy the record, churn keys, restart instances, and assert that no
/// identifier is ever reused, no stale state is ever resurrected, and no
/// commit ever regresses.
@Suite("AssetDiskCache random authority issuance")
struct AssetDiskCacheAuthorityIssuanceTests {
    func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
        let rootParent = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("DiskCacheAuthorityIssuanceScratch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootParent,
            withIntermediateDirectories: true
        )
        let root = rootParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    func limits() -> AssetCacheLimits {
        AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1_000_000,
            diskBudgetBytes: 4_000_000
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

    func issuedToken(
        from cache: AssetDiskCache,
        for cacheKey: AssetCacheKey
    ) async throws -> AssetCacheService.CacheToken {
        let snapshot = try await cache.beginIssuance(for: cacheKey)
        return AssetCacheService.CacheToken(
            generation: 0,
            issuance: 0,
            clearGeneration: 0,
            durableClearEpoch: snapshot.clearEpoch,
            diskAuthorityID: snapshot.authorityID
        )
    }

    // MARK: - (a) A destroyed record is safe to recreate, and resurrects nothing

    @Test(
        """
        Deleting a previously-issued-and-published key's authority record entirely -- the \
        predecessor design's unrecoverable "stale pair plus an older floor" scenario -- is now \
        unambiguously safe: the next issuance mints a brand-new random identifier that cannot \
        equal the destroyed one, the key's prior disposition is NOT resurrected, and an \
        independent sibling instance opened over the same directory afterward observes exactly \
        that same fresh record.
        """
    )
    func absentRecordIssuesFreshIdentifierAndResurrectsNothing() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key("01001")

            let publishToken = try await issuedToken(from: cache, for: cacheKey)
            let payload = Data([1, 2, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload),
                token: publishToken
            )
            let originalAuthorityID = try #require(publishToken.diskAuthorityID)
            let before = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(before.kind == .content)
            #expect(before.authorityID == originalAuthorityID)

            // Destroys the *only* durable authority artifact for this key.
            // There is deliberately no second copy to reconstruct it from.
            let recordName = await cache.authorityRecordFilename(for: cacheKey)
            try FileManager.default.removeItem(
                at: directory.appendingPathComponent(recordName)
            )

            let reissued = try await cache.beginIssuance(for: cacheKey)
            #expect(
                reissued.authorityID != originalAuthorityID,
                "A fresh mint can never reproduce a destroyed identifier"
            )
            #expect(reissued.revision == 1, "A recreated record restarts its own revision at 1")

            // Nothing about the key's prior applied state survived the
            // loss: the record is pristine-with-a-fresh-issuance, not a
            // reconstruction of the old `.content` disposition.
            let after = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(after == AssetDiskCache.KeyDisposition.pristine)

            // The stale, pre-loss token can never satisfy the CAS again.
            let stale = Data([9, 9, 9])
            try await cache.set(
                cacheKey,
                payload: stale,
                metadata: metadata(for: cacheKey, payload: stale),
                token: publishToken
            )
            #expect(
                try await cache.currentKeyDisposition(for: cacheKey)
                    == AssetDiskCache.KeyDisposition.pristine,
                "A pre-loss token must never resurrect state after a fresh mint"
            )

            let sibling = try AssetDiskCache(directory: directory, limits: limits())
            let siblingAuthority = try await sibling.currentKeyAuthority(for: cacheKey)
            #expect(
                siblingAuthority.issuedAuthorityID == reissued.authorityID,
                "A restart/sibling must observe exactly the fresh record, not a reconstruction"
            )
        }
    }

    // MARK: - (c) Identifiers are never reused, however much churn happens

    @Test(
        """
        Repeated publish/remove/clear churn never causes a freshly issued identifier to \
        collide with any identifier previously used for this key or any other -- the property \
        that structurally replaces the predecessor design's global ticket sequence, per-key \
        usage floor index, and issuance anchor. Every identifier is also always exactly 16 \
        bytes / 32 lowercase hex characters, and never the reserved pristine sentinel.
        """
    )
    func identifiersAreNeverReusedAcrossRepeatedChurn() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            var seen: Set<AuthorityID> = []
            let hexCharacters = Set("0123456789abcdef")

            for round in 0 ..< 40 {
                for keyIndex in 0 ..< 5 {
                    let cacheKey = try key(String(format: "%05d", 1000 + keyIndex))
                    let token = try await issuedToken(from: cache, for: cacheKey)
                    let authorityID = try #require(token.diskAuthorityID)
                    #expect(authorityID != AuthorityID.pristine)
                    #expect(authorityID.bytes.count == AuthorityID.byteCount)
                    let hex = authorityID.hexString
                    #expect(hex.count == AuthorityID.byteCount * 2)
                    #expect(hex.allSatisfy { hexCharacters.contains($0) })
                    #expect(
                        seen.insert(authorityID).inserted,
                        "A freshly minted identifier must never repeat one already issued"
                    )
                    let payload = Data([UInt8(round % 251), UInt8(keyIndex)])
                    try await cache.set(
                        cacheKey,
                        payload: payload,
                        metadata: metadata(for: cacheKey, payload: payload),
                        token: token
                    )
                    try await cache.remove(cacheKey, token: token)
                }
                if round % 10 == 9 {
                    // A whole-cache clear destroys every per-key record,
                    // which under the predecessor design was exactly the
                    // moment counters reset and became replayable.
                    try await cache.removeAll()
                }
            }
            #expect(seen.count == 200)
        }
    }
}
