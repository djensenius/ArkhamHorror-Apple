@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Fail-closed coverage for the single canonical per-key
/// ``AssetDiskCache/KeyAuthorityRecord`` file.
///
/// This cache stores exactly one authority artifact per key: issuance
/// identifier, applied disposition, and transition revision live in one
/// atomically-replaced file, with no mirror, anchor, floor index, or
/// global sequence beside it to reconstruct from. That makes the
/// contract these tests pin down very sharp:
///
/// - A record that is **absent** is unambiguously "no operation was ever
///   issued for this key", because ``AssetDiskCache/beginIssuance(for:)``
///   mints a fresh ``AuthorityID`` that cannot equal any identifier a
///   stale in-flight caller might still hold. Issuance may therefore
///   always create-if-absent.
/// - A record that is **present but unparsable** (torn, truncated,
///   tampered) is a hard, typed failure on every path — issuance,
///   mutation, and read alike. It is never repaired, never reset to the
///   pristine sentinel, and never silently treated as a clean absence.
/// - **Mutation** additionally requires an existing record: only
///   issuance may create one, so a mutation against an absent record can
///   never conjure authority for itself.
///
/// Split out of `AssetDiskCacheWriteGenerationTests.swift` purely to keep
/// that file within this package's `file_length`/`type_body_length`
/// conventions; reuses that file's own `withScratchDirectory`/`limits`/
/// `key`/`metadata`/`issuedToken` helpers.
extension AssetDiskCacheWriteGenerationTests {
    private func corrupt(
        _ cache: AssetDiskCache,
        for cacheKey: AssetCacheKey,
        with bytes: Data
    ) async throws {
        let name = await cache.authorityRecordFilename(for: cacheKey)
        let access = await cache.directoryAccess
        try access.writeTempAndFsync(tempName: name + ".tmp", data: bytes)
        try access.renameAndFsyncDirectory(from: name + ".tmp", to: name)
    }

    @Test(
        """
        Issuing an authority for a key with nothing yet published durably writes the FULL \
        canonical record (the freshly minted identifier alongside a still-pristine \
        disposition), so a corruption striking at exactly that point is provably detectable \
        rather than silently indistinguishable from a genuinely fresh key: every subsequent \
        issuance, mutation, and authority read must fail closed with a typed error.
        """
    )
    func issuanceOnlyAuthorityRecordCorruptionFailsClosedRatherThanResettingToPristine(
    ) async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key()

            let snapshot = try await cache.beginIssuance(for: cacheKey)
            #expect(snapshot.authorityID != AuthorityID.pristine)

            try await corrupt(cache, for: cacheKey, with: Data("not json".utf8))

            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: cacheKey)
            }
            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyAuthority(for: cacheKey)
            }
            await #expect(throws: AssetError.self) {
                let payload = Data([1, 2, 3])
                try await cache.set(
                    cacheKey,
                    payload: payload,
                    metadata: metadata(for: cacheKey, payload: payload),
                    token: nil
                )
            }
        }
    }

    @Test(
        """
        A torn/truncated authority record left behind by a crash mid-write is never mistaken \
        for a clean absence by a brand-new sibling instance over the same directory: that \
        sibling's own issuance must fail closed rather than silently starting this key over \
        from the pristine sentinel.
        """
    )
    func tornAuthorityRecordAfterIssuanceOnlyFailsClosedForFreshSiblingReservation() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key()

            _ = try await cache.beginIssuance(for: cacheKey)
            try await corrupt(cache, for: cacheKey, with: Data("{\"issuedAuthorityID".utf8))

            let sibling = try AssetDiskCache(directory: directory, limits: limits())
            await #expect(throws: AssetError.self) {
                _ = try await sibling.beginIssuance(for: cacheKey)
            }
        }
    }

    @Test(
        """
        A structurally well-formed record carrying an identifier that is not exactly 32 \
        lowercase hex characters is rejected exactly like unparsable bytes: AuthorityID's \
        decoder is the sole gate a tampered on-disk record has to pass, so a short, \
        uppercase, or otherwise low-entropy identifier can never enter the CAS at all.
        """
    )
    func malformedAuthorityIdentifierEncodingFailsClosed() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key()

            _ = try await cache.beginIssuance(for: cacheKey)

            let tampered = """
            {"issuedAuthorityID":"ABC","disposition":{"authorityID":"\
            00000000000000000000000000000000","kind":"tombstone"},"transitionRevision":1}
            """
            try await corrupt(cache, for: cacheKey, with: Data(tampered.utf8))

            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyAuthority(for: cacheKey)
            }
            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: cacheKey)
            }
        }
    }

    @Test(
        """
        A committed content disposition offers no protection against a corrupted record: a \
        present-but-unparsable authority record still fails closed on issuance, publish, \
        removal, and authority read alike, never silently treated as a pristine key.
        """
    )
    func corruptedAuthorityRecordWithSurvivingContentDispositionFailsClosed() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key()

            let publishToken = try await issuedToken(from: cache, for: cacheKey)
            let payload = Data([7, 7, 7])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload),
                token: publishToken
            )
            let dispositionBeforeCorruption = try await cache.currentKeyDisposition(
                for: cacheKey
            )
            #expect(dispositionBeforeCorruption.kind == .content)
            #expect(dispositionBeforeCorruption.authorityID == publishToken.diskAuthorityID)

            try await corrupt(cache, for: cacheKey, with: Data("not json".utf8))

            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: cacheKey)
            }
            let anotherPayload = Data([8, 8, 8])
            await #expect(throws: AssetError.self) {
                try await cache.set(
                    cacheKey,
                    payload: anotherPayload,
                    metadata: metadata(for: cacheKey, payload: anotherPayload),
                    token: nil
                )
            }
            await #expect(throws: AssetError.self) {
                try await cache.remove(cacheKey, token: nil)
            }
            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyAuthority(for: cacheKey)
            }
        }
    }

    @Test(
        """
        A genuinely pristine key -- one that has never had any authority issued or \
        disposition committed for it -- is unaffected by every fail-closed check above: \
        issuance succeeds and mints a fresh, non-sentinel identifier.
        """
    )
    func genuinelyPristineKeyIssuanceStillSucceedsNormally() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key()

            let snapshot = try await cache.beginIssuance(for: cacheKey)
            #expect(snapshot.authorityID != AuthorityID.pristine)
            #expect(snapshot.authorityID.hexString.count == AuthorityID.byteCount * 2)
            #expect(snapshot.revision == 1)
        }
    }

    @Test(
        """
        acceptToken requires *exact* identifier equality against the key's currently-issued \
        authority: a token carrying any other identifier -- including the reserved pristine \
        sentinel, or an identifier that was genuinely current a moment ago -- is rejected. \
        There is no ordering between two random identifiers, so there is deliberately no \
        `>=`-style tolerance anywhere in this comparison.
        """
    )
    func acceptTokenRequiresExactIdentifierEquality() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key()
            let snapshot = try await cache.beginIssuance(for: cacheKey)
            let current = snapshot.authorityID
            let other = try AuthorityID.random()
            let openRecord = try await cache.currentKeyRecord(for: cacheKey)

            func token(_ authorityID: AuthorityID?) -> AssetCacheService.CacheToken {
                AssetCacheService.CacheToken(
                    generation: 0,
                    issuance: 0,
                    durableClearEpoch: 0,
                    diskAuthorityID: authorityID
                )
            }

            let exact = await cache.acceptToken(
                token(current),
                currentEpoch: 0,
                currentRecord: openRecord
            )
            #expect(exact, "A token whose identifier is the currently-issued one must pass")

            let mismatched = await cache.acceptToken(
                token(other),
                currentEpoch: 0,
                currentRecord: openRecord
            )
            #expect(!mismatched, "Any other identifier must be rejected")

            let sentinel = await cache.acceptToken(
                token(.pristine),
                currentEpoch: 0,
                currentRecord: openRecord
            )
            #expect(!sentinel, "The reserved pristine sentinel is never a usable authority")

            let unstamped = await cache.acceptToken(
                token(nil),
                currentEpoch: 0,
                currentRecord: openRecord
            )
            #expect(!unstamped, "An unstamped token carries no authority at all")

            let wrongEpoch = await cache.acceptToken(
                token(current),
                currentEpoch: 1,
                currentRecord: openRecord
            )
            #expect(!wrongEpoch, "A superseded durable clear epoch must reject the token")
        }
    }
}
