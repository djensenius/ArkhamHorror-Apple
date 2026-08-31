@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Split out of `AssetDiskCacheAuthorityRecordMirrorTests.swift` purely
/// to keep that file within this package's `file_length`/
/// `type_body_length` conventions -- reuses that file's own
/// `mirrorTestToken`/`mirrorTestMetadata`/`primaryURL`/`mirrorURL`/
/// `encodedRecord` helpers (deliberately kept non-`private` there for
/// exactly this reuse, mirroring
/// `AssetDiskCacheWriteGenerationTests+FailClosed.swift`'s own identical
/// convention). Covers this review round's finding #2's structural
/// rejection requirements: a decoded ``AssetDiskCache/KeyAuthorityRecord``
/// that is well-formed JSON but semantically impossible (a negative
/// ticket, a disposition ahead of its own issuance, or an
/// impossible kind/hash pairing) must fail closed exactly like an
/// unparsable one -- never silently deferring to a sibling copy, since a
/// *present-but-untrustworthy* copy is a fundamentally stronger, more
/// active signal than a cleanly *absent* one (see
/// `AssetDiskCache+Disposition.swift`'s own
/// `currentAuthorityRecordLocked(for:)` doc comment) -- plus one final
/// end-to-end proof that a delayed, pre-loss caller's own historical
/// stamp cannot resurrect content once the mirror-based recovery this
/// suite's sibling file exercises has already let a fresh mutation land.
extension AssetDiskCacheTests {
    @Test("A structurally invalid record (negative ticket) is rejected, not merely decoded")
    func negativeTicketRecordIsRejected() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")

            // Forces root-authority initialization on a genuinely empty
            // root first -- see `tornPairResolvesToHigherIssuedTicketAndSelfHeals`'s
            // identical comment for why.
            _ = try await cache.currentKeyDisposition(for: key("09999"))

            // Both copies carry the exact same invalid record. A
            // structurally invalid copy is *never* silently deferred to
            // its sibling -- unlike a clean absence, it is active
            // evidence against trusting this key's authority at all, so
            // this must fail closed rather than resetting to pristine
            // or reporting any value.
            let invalidData = try encodedRecord(
                issuedTicket: -1,
                ticket: 0,
                kind: .tombstone,
                contentHash: nil,
                revision: 1
            )

            try await invalidData.write(
                to: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )
            try await invalidData.write(
                to: mirrorURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )

            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyDisposition(for: cacheKey)
            }
        }
    }

    @Test(
        "A disposition ticket ahead of its own issuedTicket (impossible in production) is rejected"
    )
    func dispositionAheadOfIssuedTicketIsRejected() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")

            _ = try await cache.currentKeyDisposition(for: key("09999"))

            let invalidData = try encodedRecord(
                issuedTicket: 1,
                ticket: 5,
                kind: .content,
                contentHash: String(repeating: "c", count: 64),
                revision: 1
            )
            try await invalidData.write(
                to: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )
            try await invalidData.write(
                to: mirrorURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )

            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyDisposition(for: cacheKey)
            }
        }
    }

    @Test("A .content disposition carrying no content hash (impossible in production) is rejected")
    func contentDispositionWithoutHashIsRejected() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")

            _ = try await cache.currentKeyDisposition(for: key("09999"))

            let invalidData = try encodedRecord(
                issuedTicket: 3,
                ticket: 3,
                kind: .content,
                contentHash: nil,
                revision: 1
            )
            try await invalidData.write(
                to: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )
            try await invalidData.write(
                to: mirrorURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )

            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyDisposition(for: cacheKey)
            }
        }
    }

    @Test("A .tombstone disposition carrying a content hash (impossible in production) is rejected")
    func tombstoneDispositionWithHashIsRejected() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")

            _ = try await cache.currentKeyDisposition(for: key("09999"))

            let invalidData = try encodedRecord(
                issuedTicket: 3,
                ticket: 3,
                kind: .tombstone,
                contentHash: String(repeating: "d", count: 64),
                revision: 1
            )
            try await invalidData.write(
                to: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )
            try await invalidData.write(
                to: mirrorURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )

            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyDisposition(for: cacheKey)
            }
        }
    }

    @Test(
        """
        A structurally invalid primary paired with a structurally valid mirror still fails \
        closed -- a corrupt copy is a fundamentally different, stronger signal than a cleanly \
        absent one, and is never allowed to defer to even an otherwise-trustworthy sibling; \
        this preserves a prior review round's own "present-but-unparsable always fails closed" \
        requirement even now that a second copy exists
        """
    )
    func invalidPrimaryWithValidMirrorStillFailsClosed() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([9, 9, 9])
            let issuance = try await cache.beginIssuance(for: cacheKey)
            let token = mirrorTestToken(from: issuance)
            let entryMetadata = mirrorTestMetadata(
                for: cacheKey,
                payload: payload,
                issuance: issuance
            )
            try await cache.set(cacheKey, payload: payload, metadata: entryMetadata, token: token)

            // Corrupts the primary's bytes in place (not merely
            // deleting it) with a structurally invalid record, leaving
            // the mirror's own already-valid copy from the `set` call
            // above untouched.
            let corrupt = try encodedRecord(
                issuedTicket: -5,
                ticket: 0,
                kind: .tombstone,
                contentHash: nil,
                revision: 1
            )
            try await corrupt.write(
                to: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )

            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyDisposition(for: cacheKey)
            }
        }
    }

    @Test(
        """
        A delayed old token cannot resurrect content after the mirror-based recovery: once a \
        fresh mutation durably lands after a single-copy loss, an older, still-suspended \
        caller's own pre-loss historical stamp must still fail revalidation
        """
    )
    func delayedOldTokenCannotResurrectAfterRecovery() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3])
            let issuance = try await cache.beginIssuance(for: cacheKey)
            let token = mirrorTestToken(from: issuance)
            let entryMetadata = mirrorTestMetadata(
                for: cacheKey,
                payload: payload,
                issuance: issuance
            )
            try await cache.set(cacheKey, payload: payload, metadata: entryMetadata, token: token)

            // Lose the primary copy, then let a fresh, independent
            // mutation land -- simulating a sibling/restart continuing
            // to use this key normally after the loss.
            try await FileManager.default.removeItem(
                at: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )
            let newPayload = Data([4, 5, 6])
            let newIssuance = try await cache.beginIssuance(for: cacheKey)
            let newToken = mirrorTestToken(from: newIssuance)
            let newMetadata = mirrorTestMetadata(
                for: cacheKey,
                payload: newPayload,
                issuance: newIssuance
            )
            try await cache.set(
                cacheKey,
                payload: newPayload,
                metadata: newMetadata,
                token: newToken
            )

            // The old, pre-loss caller's own historical stamp (captured
            // before either the loss or the fresh mutation) must not be
            // able to pass revalidation now.
            let staleRevalidation = try await cache.beginRevalidationIssuance(
                for: cacheKey,
                expectedClearEpoch: issuance.clearEpoch,
                expectedAppliedTicket: issuance.writeGeneration,
                expectedContentHash: entryMetadata.payloadSHA256Hex
            )
            #expect(
                staleRevalidation == nil,
                "A delayed old token must not resurrect content after a fresh mutation"
            )

            let hit = try await cache.get(cacheKey)
            #expect(hit?.payload == newPayload)
        }
    }
}
