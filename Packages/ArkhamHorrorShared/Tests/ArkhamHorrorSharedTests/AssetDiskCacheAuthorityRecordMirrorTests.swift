@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of this review round's finding #2: a
/// key's durable per-key authority record (`AssetDiskCache+Disposition.swift`'s
/// ``AssetDiskCache/KeyAuthorityRecord``, merging the issuance counter
/// and applied disposition into one file) must not treat a *missing*
/// record as unconditionally pristine — an independent loss/corruption
/// of that single file after real prior use is indistinguishable, from
/// that file alone, from a key that has never been issued a ticket at
/// all, letting an already-issued ticket be silently reissued.
///
/// This fix keeps two independently-stored copies (the primary at
/// ``AssetDiskCache/appliedTicketFilename(for:)`` and the mirror at
/// ``AssetDiskCache/authorityRecordMirrorFilename(for:)``), each
/// individually structurally validated
/// (`AssetDiskCache+Disposition.swift`'s private `isValidAuthorityRecord`)
/// before being trusted, and reconciled deterministically when they
/// disagree. These tests drive that reconciliation directly by writing
/// raw bytes to one or both copies' own on-disk names — exactly the
/// "independent loss of exactly one file" scenario a fault-injection
/// helper cannot itself express (fault injection only intercepts this
/// cache's own writes, never a pre-existing file's already-committed
/// bytes) — then reading the key's authority back through the public
/// ``AssetDiskCache/currentKeyDisposition(for:)``/
/// ``AssetDiskCache/currentKeyAuthority(for:)`` surface, exactly as
/// production code would.
extension AssetDiskCacheTests {
    /// Constructs a `CacheToken` carrying exactly `snapshot`'s durable
    /// authority — identical in shape to
    /// `AssetDiskCacheDispositionTests.swift`'s own private helper of the
    /// same purpose, but deliberately kept non-`private` *here* so this
    /// suite's own `+ValidationRejection.swift` split file can reuse it,
    /// mirroring `AssetDiskCacheWriteGenerationTests+FailClosed.swift`'s
    /// identical convention.
    func mirrorTestToken(
        from snapshot: AssetDiskCache.IssuanceSnapshot
    ) -> AssetCacheService.CacheToken {
        AssetCacheService.CacheToken(
            generation: 0,
            issuance: 0,
            durableClearEpoch: snapshot.clearEpoch,
            diskWriteGeneration: snapshot.writeGeneration
        )
    }

    func mirrorTestMetadata(
        for cacheKey: AssetCacheKey,
        payload: Data,
        issuance: AssetDiskCache.IssuanceSnapshot
    ) -> AssetCacheMetadata {
        let base = metadata(for: cacheKey, payload: payload)
        return AssetCacheMetadata(
            cacheKeyHex: base.cacheKeyHex,
            contentType: base.contentType,
            encodedByteCount: base.encodedByteCount,
            width: base.width,
            height: base.height,
            payloadSHA256Hex: base.payloadSHA256Hex,
            etag: base.etag,
            lastModified: base.lastModified,
            resolvedURLString: base.resolvedURLString,
            insertedAt: base.insertedAt,
            accessSequence: base.accessSequence,
            clearEpochAtPublication: issuance.clearEpoch,
            writeGenerationAtPublication: issuance.writeGeneration
        )
    }

    func primaryURL(
        directory: URL,
        cache: AssetDiskCache,
        cacheKey: AssetCacheKey
    ) async -> URL {
        let name = await cache.appliedTicketFilename(for: cacheKey)
        return directory.appendingPathComponent(name)
    }

    func mirrorURL(
        directory: URL,
        cache: AssetDiskCache,
        cacheKey: AssetCacheKey
    ) async -> URL {
        let name = await cache.authorityRecordMirrorFilename(for: cacheKey)
        return directory.appendingPathComponent(name)
    }

    func encodedRecord(
        issuedTicket: Int,
        ticket: Int,
        kind: AssetDiskCache.KeyDispositionKind,
        contentHash: String?
    ) throws -> Data {
        let record = AssetDiskCache.KeyAuthorityRecord(
            issuedTicket: issuedTicket,
            disposition: AssetDiskCache.KeyDisposition(
                ticket: ticket,
                kind: kind,
                contentHash: contentHash
            )
        )
        return try JSONEncoder.assetCache().encode(record)
    }

    @Test(
        """
        Deleting only the primary copy after a real publish does not reset the key to \
        pristine -- the surviving mirror alone still reports the exact same content, and a \
        fresh reservation for the same key must not be able to replay the already-issued ticket
        """
    )
    func primaryLossAloneDoesNotResetToPristine() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            let issuance = try await cache.beginIssuance(for: cacheKey)
            let token = mirrorTestToken(from: issuance)
            let entryMetadata = mirrorTestMetadata(
                for: cacheKey,
                payload: payload,
                issuance: issuance
            )
            try await cache.set(cacheKey, payload: payload, metadata: entryMetadata, token: token)

            // Simulates an independent loss of exactly the primary copy
            // -- deleting a byte-for-byte already-committed file, which
            // no fault-injection hook (those only intercept this cache's
            // own future writes) can express.
            try await FileManager.default.removeItem(
                at: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )

            let disposition = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(
                disposition.kind == .content,
                "The surviving mirror alone must still be trusted"
            )
            #expect(disposition.ticket == issuance.writeGeneration)
            #expect(disposition.contentHash == entryMetadata.payloadSHA256Hex)

            let authority = try await cache.currentKeyAuthority(for: cacheKey)
            #expect(
                authority.issuedTicket == issuance.writeGeneration,
                "The issuance counter must not have been reset to 0 by the primary's own loss"
            )

            // A fresh caller's historical stamp exactly matching the
            // (correctly still-current) publication must still pass a
            // conditional revalidation.
            let revalidation = try await cache.beginRevalidationIssuance(
                for: cacheKey,
                expectedClearEpoch: issuance.clearEpoch,
                expectedAppliedTicket: issuance.writeGeneration,
                expectedContentHash: entryMetadata.payloadSHA256Hex
            )
            #expect(
                revalidation != nil,
                "The still-current publication must still be revalidatable"
            )

            // The primary copy must have self-healed from the surviving
            // mirror -- proving *this* read's own repair, not merely
            // that the mirror alone happened to satisfy this one call.
            #expect(await FileManager.default.fileExists(
                atPath: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey).path
            ))
        }
    }

    @Test(
        """
        Deleting only the mirror copy after a real publish does not reset the key to pristine \
        -- the surviving primary alone still reports the exact same content, and it self-heals \
        the missing mirror on next read
        """
    )
    func mirrorLossAloneDoesNotResetToPristine() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            let issuance = try await cache.beginIssuance(for: cacheKey)
            let token = mirrorTestToken(from: issuance)
            let entryMetadata = mirrorTestMetadata(
                for: cacheKey,
                payload: payload,
                issuance: issuance
            )
            try await cache.set(cacheKey, payload: payload, metadata: entryMetadata, token: token)

            try await FileManager.default.removeItem(
                at: mirrorURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )

            let disposition = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(disposition.kind == .content)
            #expect(disposition.ticket == issuance.writeGeneration)

            let authority = try await cache.currentKeyAuthority(for: cacheKey)
            #expect(authority.issuedTicket == issuance.writeGeneration)

            #expect(await FileManager.default.fileExists(
                atPath: mirrorURL(directory: directory, cache: cache, cacheKey: cacheKey).path
            ))
        }
    }

    @Test(
        "A key that has genuinely never been issued a ticket -- both copies absent -- is pristine"
    )
    func genuinelyPristineKeyWithBothCopiesAbsentReportsZero() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")

            let disposition = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(disposition.kind == .tombstone)
            #expect(disposition.ticket == 0)
            let authority = try await cache.currentKeyAuthority(for: cacheKey)
            #expect(authority.issuedTicket == 0)
        }
    }

    @Test(
        """
        A torn pair -- both copies present and individually valid, but disagreeing (a crash \
        between the mirror's write and the primary's) -- resolves to the higher issuedTicket \
        copy, since the mirror is always written first and can therefore only ever be as new \
        as or newer than the primary; the loser is then self-healed to match
        """
    )
    func tornPairResolvesToHigherIssuedTicketAndSelfHeals() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            // Forces root-authority initialization while the root is
            // still genuinely empty, *before* this test writes raw bytes
            // directly to `cacheKey`'s own authority-record files below
            // -- otherwise `ensureRootAuthorityInitializedLocked`
            // correctly refuses to treat a root with unexplained
            // surviving entries as pristine (a prior review round's own
            // fix), which this test's raw-byte injection would
            // otherwise trip for an unrelated reason.
            _ = try await cache.currentKeyDisposition(for: key("09999"))

            // Simulates the crash window `commitAuthorityRecordLocked`
            // itself documents: the mirror write landed, but the
            // primary's own write is still whatever *older* value was
            // last durably committed there.
            let newerHash = String(repeating: "a", count: 64)
            let olderHash = String(repeating: "b", count: 64)
            let newerRecordData = try encodedRecord(
                issuedTicket: 5,
                ticket: 5,
                kind: .content,
                contentHash: newerHash
            )
            let olderRecordData = try encodedRecord(
                issuedTicket: 3,
                ticket: 3,
                kind: .content,
                contentHash: olderHash
            )
            try await newerRecordData.write(
                to: mirrorURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )
            try await olderRecordData.write(
                to: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )

            let disposition = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(
                disposition.ticket == 5,
                "The higher-issuedTicket copy (the mirror, always written first) must win"
            )
            #expect(disposition.contentHash == newerHash)

            let authority = try await cache.currentKeyAuthority(for: cacheKey)
            #expect(authority.issuedTicket == 5)

            // The primary (the loser) must have been overwritten to
            // match the winner -- proving the torn pair actually
            // self-heals rather than merely being tolerated on each read.
            let healedPrimaryData = try await Data(
                contentsOf: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )
            let healedPrimary = try JSONDecoder.assetCache().decode(
                AssetDiskCache.KeyAuthorityRecord.self,
                from: healedPrimaryData
            )
            #expect(healedPrimary.issuedTicket == 5)
            #expect(healedPrimary.disposition.contentHash == newerHash)
        }
    }
}
