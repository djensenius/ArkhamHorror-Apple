@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Forced-value coverage for the one part of ``AssetDiskCache``'s
/// issuance path that sampling real randomness can never reach.
///
/// A 128-bit CSPRNG draw colliding with a specific value is a
/// `2^-128`-per-attempt event, so "take 200 natural samples and observe
/// no collision" (see
/// `AssetDiskCacheAuthorityIssuanceTests.identifiersAreNeverReusedAcrossRepeatedChurn()`,
/// which remains necessary) can never exercise the *handling* of one.
/// These tests instead force the exact values and the exact hard failure
/// that ``AssetDiskCache/mintFreshAuthorityIDLocked(distinctFrom:)`` is
/// written to reject, through this instance's own
/// ``AuthorityIDFaultInjectionState``, and pin that the result is always
/// a bounded retry followed by either a usable identifier or a typed
/// failure -- never a trap, never an unbounded loop, and never a
/// durable write.
@Suite("AssetDiskCache authority identifier collision handling")
struct AssetDiskCacheAuthorityMintTests {
    private let fixtures = AssetDiskCacheAuthorityIssuanceTests()

    private func forcedIdentifier(_ byte: UInt8) throws -> AuthorityID {
        try #require(
            AuthorityID(hexString: String(repeating: String(format: "%02x", byte), count: 16))
        )
    }

    // MARK: - Record validation

    @Test(
        """
        A record whose issuedAuthorityID is the reserved all-zero sentinel while everything \
        else about it is live is structurally impossible and is rejected. Before the guard \
        that pins "the sentinel may only appear on a wholly pristine record", this exact \
        shape passed: the whole-record equality check reads `(revision == 0) == (record == \
        .pristine)` as `false == false`, because the live .content disposition alone already \
        makes the record differ from the pristine sentinel.
        """
    )
    func pristineIssuedIdentifierWithLiveDispositionIsRejected() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: fixtures.limits())
            let live = try forcedIdentifier(0xAB)
            let contentHash = AssetPayloadHasher.sha256Hex(Data([1, 2, 3]))
            let crafted = AssetDiskCache.KeyAuthorityRecord(
                issuedAuthorityID: .pristine,
                disposition: AssetDiskCache.KeyDisposition(
                    authorityID: live,
                    kind: .content,
                    contentHash: contentHash
                ),
                transitionRevision: 5
            )
            #expect(crafted != AssetDiskCache.KeyAuthorityRecord.pristine)
            #expect(await cache.isValidAuthorityRecord(crafted) == false)

            // ...and the same shape planted on disk is a hard,
            // fail-closed read, never silently accepted as this key's
            // durable authority.
            let cacheKey = try fixtures.key("01001")
            let recordName = await cache.authorityRecordFilename(for: cacheKey)
            try JSONEncoder.assetCache().encode(crafted)
                .write(to: directory.appendingPathComponent(recordName))
            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyRecord(for: cacheKey)
            }
        }
    }

    @Test("The genuinely pristine record, and an ordinary live one, both still validate")
    func legitimateRecordShapesStillValidate() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: fixtures.limits())
            #expect(
                await cache.isValidAuthorityRecord(AssetDiskCache.KeyAuthorityRecord.pristine)
            )
            let issued = try forcedIdentifier(0x11)
            #expect(
                await cache.isValidAuthorityRecord(
                    AssetDiskCache.KeyAuthorityRecord(
                        issuedAuthorityID: issued,
                        disposition: .pristine,
                        transitionRevision: 1
                    )
                ),
                "A key that has been issued but never published is an ordinary, valid record"
            )
        }
    }

    // MARK: - (a) The reserved pristine sentinel is never issued

    @Test(
        """
        A random source that returns the reserved all-zero identifier is rejected by the \
        bounded retry loop and re-drawn: the issued identifier is a real one, exactly two \
        mint attempts were made, and nothing pristine was ever durably recorded as issued.
        """
    )
    func forcedPristineDrawIsRejectedAndReDrawn() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: fixtures.limits())
            let cacheKey = try fixtures.key("01001")
            await cache.installAuthorityIDFaultInjection(forcedIdentifiers: [.pristine])

            let snapshot = try await cache.beginIssuance(for: cacheKey)
            #expect(snapshot.authorityID != AuthorityID.pristine)
            #expect(await cache.authorityIDMintCallCount == 2)
            let record = try await cache.currentKeyRecord(for: cacheKey)
            #expect(record.issuedAuthorityID == snapshot.authorityID)
        }
    }

    // MARK: - (b)/(c) A draw colliding with either recorded identifier is rejected

    @Test(
        """
        A random source that returns exactly the identifier this key's record already names \
        as most recently issued is rejected and re-drawn, so an issuance can never \
        accidentally re-mint the authority a stale in-flight caller is still holding.
        """
    )
    func forcedCollisionWithCurrentIssuedIdentifierIsRejected() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: fixtures.limits())
            let cacheKey = try fixtures.key("01001")

            let first = try await cache.beginIssuance(for: cacheKey)
            let attemptsBefore = await cache.authorityIDMintCallCount
            await cache.installAuthorityIDFaultInjection(
                forcedIdentifiers: [first.authorityID]
            )
            let second = try await cache.beginIssuance(for: cacheKey)
            #expect(second.authorityID != first.authorityID)
            #expect(await cache.authorityIDMintCallCount - attemptsBefore == 2)
        }
    }

    @Test(
        """
        A random source that returns exactly the identifier of this key's currently APPLIED \
        disposition -- a value distinct from its most recently issued one -- is likewise \
        rejected and re-drawn: an issuance whose identifier coincides with an already-applied \
        one is indistinguishable, to removeIfApplied's exact-match retraction contract, from \
        "this exact operation's own mutation is what is applied".
        """
    )
    func forcedCollisionWithAppliedDispositionIdentifierIsRejected() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: fixtures.limits())
            let cacheKey = try fixtures.key("01001")

            let publishToken = try await fixtures.issuedToken(from: cache, for: cacheKey)
            let payload = Data([7, 7, 7])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: fixtures.metadata(for: cacheKey, payload: payload),
                token: publishToken
            )
            // A second issuance moves `issuedAuthorityID` forward while
            // leaving the applied disposition at the publish's own
            // identifier, so the two fields are now genuinely different.
            let reissued = try await cache.beginIssuance(for: cacheKey)
            let applied = try await cache.currentKeyDisposition(for: cacheKey)
            let appliedIdentifier = applied.authorityID
            #expect(appliedIdentifier != reissued.authorityID)

            let attemptsBefore = await cache.authorityIDMintCallCount
            await cache.installAuthorityIDFaultInjection(
                forcedIdentifiers: [appliedIdentifier]
            )
            let third = try await cache.beginIssuance(for: cacheKey)
            #expect(third.authorityID != appliedIdentifier)
            #expect(third.authorityID != reissued.authorityID)
            #expect(await cache.authorityIDMintCallCount - attemptsBefore == 2)
        }
    }

    // MARK: - (d) A permanently colliding source terminates, bounded

    @Test(
        """
        A random source that keeps returning a forbidden value forever stops at the \
        documented attempt bound with a typed persistence failure -- it never hangs, never \
        traps, and never durably records anything for the key whose issuance it refused.
        """,
        .timeLimit(.minutes(1))
    )
    func permanentlyCollidingSourceFailsClosedAtTheAttemptBound() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: fixtures.limits())
            let cacheKey = try fixtures.key("01001")
            let first = try await cache.beginIssuance(for: cacheKey)
            let attemptsBefore = await cache.authorityIDMintCallCount

            await cache.installAuthorityIDFaultInjection(
                forcedIdentifiers: [first.authorityID],
                repeatsFinalForcedIdentifier: true
            )
            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: cacheKey)
            }
            #expect(
                await cache.authorityIDMintCallCount - attemptsBefore
                    == AssetDiskCache.authorityIDMintAttemptLimit,
                "The retry loop must stop at exactly its documented bound"
            )
            let record = try await cache.currentKeyRecord(for: cacheKey)
            #expect(
                record.issuedAuthorityID == first.authorityID,
                "A refused issuance must leave the previous record exactly as it was"
            )
            #expect(record.transitionRevision == first.revision)
        }
    }

    // MARK: - (e) A hard randomness failure propagates and writes nothing

    @Test(
        """
        The underlying randomness call itself reporting a hard failure surfaces as a typed \
        persistence failure -- never a weaker fallback source, never a crash -- and leaves \
        the key's record entirely uncreated.
        """,
        .timeLimit(.minutes(1))
    )
    func hardRandomnessFailurePropagatesAndWritesNothing() async throws {
        try await fixtures.withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: fixtures.limits())
            let cacheKey = try fixtures.key("01001")
            await cache.installAuthorityIDFaultInjection(forcedFailuresRemaining: 1)

            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: cacheKey)
            }
            #expect(
                await cache.authorityIDMintCallCount == 1,
                "A hard randomness failure propagates immediately; it is not retried"
            )
            let record = try await cache.currentKeyRecord(for: cacheKey)
            #expect(record == AssetDiskCache.KeyAuthorityRecord.pristine)
            #expect(
                await FileManager.default.fileExists(
                    atPath: directory
                        .appendingPathComponent(
                            cache.authorityRecordFilename(for: cacheKey)
                        )
                        .path
                ) == false,
                "No authority record file may exist for a key whose issuance failed"
            )
        }
    }
}
