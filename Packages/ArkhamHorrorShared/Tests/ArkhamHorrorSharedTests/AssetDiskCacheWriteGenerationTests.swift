@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Proves ``AssetDiskCache``'s durable, cross-instance/cross-process
/// per-key write-generation counter (`AssetDiskCache+WriteGeneration.swift`,
/// `AssetDiskCache+TokenCAS.swift`) — not merely this package's earlier,
/// purely actor-local `keyLatestToken`/`keyClearGeneration` bookkeeping —
/// is what makes two genuinely independent ``AssetDiskCache`` instances
/// (exactly as two separate OS processes, or two separate service graphs
/// in one process, sharing only an on-disk directory would look) agree on
/// write ordering for the same key.
///
/// Before this mechanism, `AssetDiskCache.set(_:payload:metadata:token:)`
/// accepted *any* non-`nil` token unconditionally (there was no disk-side
/// compare at all): an older instance's delayed write, completing after a
/// newer, independent instance already published (or invalidated) the
/// same key, could freely overwrite or resurrect state the newer instance
/// had already superseded, because neither instance's own token carried
/// any value the *other* instance could compare against.
@Suite("AssetDiskCache durable per-key write generation")
struct AssetDiskCacheWriteGenerationTests {
    private func withScratchDirectory(_ body: (URL) async throws -> Void) async throws {
        let rootParent = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("DiskCacheWriteGenerationScratch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootParent,
            withIntermediateDirectories: true
        )
        let root = rootParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private func limits() -> AssetCacheLimits {
        AssetCacheLimits(
            maxEncodedBytes: 1_000_000,
            maxDimension: 8192,
            maxPixelCount: 32_000_000,
            memoryBudgetBytes: 1_000_000,
            diskBudgetBytes: 1_000_000
        )
    }

    private func key(_ rawCardCode: String = "01001") throws -> AssetCacheKey {
        let identifier = try AssetIdentifier.cardCode(rawCardCode)
        let assetKey = AssetKey(category: .card(.art, identifier))
        let candidates = AssetLocator.candidates(for: assetKey, digest: FakeDigestLookup())
        return AssetCacheKey(for: assetKey, candidates: candidates)
    }

    private func metadata(
        for cacheKey: AssetCacheKey,
        payload: Data,
        resolvedURLString: String = "https://example.com/a"
    ) -> AssetCacheMetadata {
        AssetCacheMetadata(
            cacheKeyHex: cacheKey.digestHex,
            contentType: "image/png",
            encodedByteCount: payload.count,
            width: 4,
            height: 4,
            payloadSHA256Hex: AssetPayloadHasher.sha256Hex(payload),
            etag: nil,
            lastModified: nil,
            resolvedURLString: resolvedURLString,
            insertedAt: Date(),
            accessSequence: AssetAccessSequence(0)
        )
    }

    /// A token stamped exactly the way every real ``AssetCacheService``
    /// call site now stamps one: both halves of its durable authority
    /// (clear epoch, disk write generation) captured together via
    /// ``AssetDiskCache/beginIssuance(for:)`` at issuance time.
    private func issuedToken(
        from cache: AssetDiskCache,
        for cacheKey: AssetCacheKey
    ) async throws -> AssetCacheService.CacheToken {
        let snapshot = try await cache.beginIssuance(for: cacheKey)
        return AssetCacheService.CacheToken(
            generation: 0,
            issuance: 0,
            clearGeneration: 0,
            durableClearEpoch: snapshot.clearEpoch,
            diskWriteGeneration: snapshot.writeGeneration
        )
    }

    @Test(
        """
        An older instance's delayed publish, issued (its durable write-generation snapshot \
        captured) before a completely independent sibling instance -- sharing only the same \
        on-disk directory -- publishes its own newer write for the exact same key, must not \
        overwrite that newer instance's payload once it finally attempts to write, even \
        though the older instance's own write only runs second
        """
    )
    func olderIssuedPublishCannotOverwriteNewerSiblingPublish() async throws {
        try await withScratchDirectory { directory in
            let cacheKey = try key()
            let cacheA = try AssetDiskCache(directory: directory, limits: limits())
            let cacheB = try AssetDiskCache(directory: directory, limits: limits())

            // A captures its issuance snapshot first -- modeling a fetch
            // that started earlier but is held up (network latency, a
            // slow decode) before it ever gets to write.
            let tokenA = try await issuedToken(from: cacheA, for: cacheKey)

            // B, a completely independent instance, issues *and completes*
            // its own newer write for this same key before A ever gets a
            // chance to.
            let tokenB = try await issuedToken(from: cacheB, for: cacheKey)
            let payloadB = Data([2, 2, 2])
            try await cacheB.set(
                cacheKey,
                payload: payloadB,
                metadata: metadata(for: cacheKey, payload: payloadB),
                token: tokenB
            )

            // A's write, using its *older* pre-captured token, must be
            // silently rejected as stale -- never overwriting B's
            // already-published, newer generation.
            let payloadA = Data([1, 1, 1])
            try await cacheA.set(
                cacheKey,
                payload: payloadA,
                metadata: metadata(for: cacheKey, payload: payloadA),
                token: tokenA
            )

            let fetched = try #require(try await cacheA.get(cacheKey))
            #expect(
                fetched.payload == payloadB,
                "The older-issued write must never win against an already-applied newer one"
            )
        }
    }

    @Test(
        """
        An older instance's delayed removal, issued before a completely independent sibling \
        instance publishes its own newer write for the exact same key, must not delete that \
        newer instance's just-published entry
        """
    )
    func olderIssuedRemovalCannotDeleteNewerSiblingPublish() async throws {
        try await withScratchDirectory { directory in
            let cacheKey = try key()
            let cacheA = try AssetDiskCache(directory: directory, limits: limits())
            let cacheB = try AssetDiskCache(directory: directory, limits: limits())

            let tokenA = try await issuedToken(from: cacheA, for: cacheKey)

            let tokenB = try await issuedToken(from: cacheB, for: cacheKey)
            let payloadB = Data([4, 4, 4])
            try await cacheB.set(
                cacheKey,
                payload: payloadB,
                metadata: metadata(for: cacheKey, payload: payloadB),
                token: tokenB
            )

            // A's own delayed removal -- e.g. modeling a stale,
            // now-superseded conditional-404 invalidation -- must not
            // remove the entry B just published under a strictly newer
            // write generation.
            try await cacheA.remove(cacheKey, token: tokenA)

            let fetched = try #require(try await cacheA.get(cacheKey))
            #expect(
                fetched.payload == payloadB,
                "A stale older-issued removal must never delete a newer sibling's applied write"
            )
        }
    }

    @Test(
        """
        A newer instance's definitive removal (e.g. a conditional 404 invalidation) after an \
        older instance already published must actually take effect: the newer operation is \
        never itself treated as stale merely because it is a removal rather than a publish
        """
    )
    func newerIssuedRemovalDoesTakeEffectAfterOlderPublish() async throws {
        try await withScratchDirectory { directory in
            let cacheKey = try key()
            let cacheA = try AssetDiskCache(directory: directory, limits: limits())
            let cacheB = try AssetDiskCache(directory: directory, limits: limits())

            let tokenA = try await issuedToken(from: cacheA, for: cacheKey)
            let payloadA = Data([9, 9, 9])
            try await cacheA.set(
                cacheKey,
                payload: payloadA,
                metadata: metadata(for: cacheKey, payload: payloadA),
                token: tokenA
            )

            // B issues its own token strictly *after* A's publish already
            // landed, so B's snapshot reflects the generation A's write
            // just advanced to.
            let tokenB = try await issuedToken(from: cacheB, for: cacheKey)
            try await cacheB.remove(cacheKey, token: tokenB)

            let fetched = try await cacheA.get(cacheKey)
            #expect(fetched == nil, "A genuinely newer-issued removal must actually take effect")
        }
    }

    @Test(
        """
        A key's durable write-generation counter file survives an ordinary per-key removal \
        (it is not itself deleted the way the payload/metadata pair is), so a still-in-flight \
        operation issued before that removal cannot later resurrect content for the same key \
        by finding no generation history to compare against
        """
    )
    func writeGenerationSurvivesOrdinaryRemoval() async throws {
        try await withScratchDirectory { directory in
            let cacheKey = try key()
            let cache = try AssetDiskCache(directory: directory, limits: limits())

            let firstToken = try await issuedToken(from: cache, for: cacheKey)
            let firstPayload = Data([1])
            try await cache.set(
                cacheKey,
                payload: firstPayload,
                metadata: metadata(for: cacheKey, payload: firstPayload),
                token: firstToken
            )
            try await cache.remove(cacheKey, token: nil)

            // A brand-new operation for this key, issued strictly after
            // the removal, must capture a strictly greater write
            // generation than `firstToken` did -- proving the removal
            // itself durably advanced the counter rather than deleting it
            // back to a baseline a still-suspended, pre-removal operation
            // (like `firstToken`, if it had been held up rather than
            // already applied) could still satisfy.
            let secondToken = try await issuedToken(from: cache, for: cacheKey)
            #expect(
                secondToken.diskWriteGeneration != nil
                    && firstToken.diskWriteGeneration != nil
                    && secondToken.diskWriteGeneration! > firstToken.diskWriteGeneration!,
                "A post-removal issuance must observe a strictly advanced write generation"
            )

            // `firstToken` itself, replayed now, must still be correctly
            // rejected as stale -- not accepted merely because the key
            // currently has no entry to protect.
            let staleReplay = Data([2])
            try await cache.set(
                cacheKey,
                payload: staleReplay,
                metadata: metadata(for: cacheKey, payload: staleReplay),
                token: firstToken
            )
            let fetched = try await cache.get(cacheKey)
            #expect(fetched == nil, "A stale pre-removal token must never resurrect this key")
        }
    }
}
