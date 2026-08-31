@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of this review round's finding #2 (the
/// LATEST round: merging the previously-separate `.gen` issuance
/// counter and `.applied` disposition file into one atomically-written
/// ``AssetDiskCache/KeyAuthorityRecord`` -- see
/// `AssetDiskCache+Disposition.swift`'s own type-level doc comment for
/// the full reasoning behind the merge). The three tests this file
/// previously contained directly manipulated a standalone `.gen` file
/// (via a now-removed `writeGenerationFilename(for:)` helper) to
/// reproduce "issuance counter lost while disposition survives" -- that
/// exact scenario is now structurally impossible, since both halves are
/// the same on-disk artifact and can no longer independently diverge.
/// This file's tests instead prove the properties that specific merge
/// actually delivers: (1) issuing a ticket with nothing yet published
/// already durably anchors that ticket in the very same file a
/// disposition would occupy, so a corruption at that exact point -- a
/// window the prior two-file design left completely undetectable, since
/// no `.applied` file existed yet at all -- is now provably detectable;
/// and (2) a present-but-unparsable (torn/partial) authority record
/// always fails closed rather than ever being treated as a clean
/// absence. Split out of `AssetDiskCacheWriteGenerationTests.swift`
/// purely to keep that file within this package's `file_length`/
/// `type_body_length` conventions; reuses that file's own
/// `withScratchDirectory`/`limits`/`key`/`metadata`/`issuedToken`
/// helpers.
extension AssetDiskCacheWriteGenerationTests {
    // MARK: - Merged authority record fail-closed (review round: HIGH #2)

    @Test(
        """
        Before this round's merge, a ticket issued for a key with nothing yet published wrote \
        *only* the bare `.gen` counter -- no `.applied` file existed for that key at all yet \
        -- so a fault that struck that lone `.gen` file was indistinguishable, on its own, from \
        a genuinely pristine key that had never had a ticket issued for it at all: reads would \
        fall back to zero and a delayed/duplicate reservation could silently replay ticket 1. \
        This round's merge closes that window: `beginIssuance` now durably writes the FULL \
        merged authority record (the issued ticket alongside a still-pristine disposition) even \
        when nothing has ever been published for this key, so a corruption at this exact point \
        is now provably detectable rather than silently indistinguishable from a fresh key.
        """
    )
    func issuanceOnlyAuthorityRecordCorruptionFailsClosedRatherThanResettingToPristine(
    ) async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key()

            let snapshot = try await cache.beginIssuance(for: cacheKey)
            #expect(snapshot.writeGeneration == 1)

            // Corrupts the single merged authority record -- present,
            // but unparsable -- immediately after issuance, strictly
            // before any publish for this key has ever happened.
            let name = await cache.appliedTicketFilename(for: cacheKey)
            let access = await cache.directoryAccess
            try access.writeTempAndFsync(tempName: name + ".tmp", data: Data("not json".utf8))
            try access.renameAndFsyncDirectory(from: name + ".tmp", to: name)

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
        A issues ticket 1 for a key (nothing published yet) and then this exact merged \
        authority record is torn -- a partial/truncated fragment left behind, simulating a \
        crash mid-write, never a clean absence. A fresh sibling instance's own subsequent \
        reservation for the same key must fail closed rather than silently resuming from zero \
        and reissuing ticket 1 again: under the prior, now-removed two-file design this exact \
        corruption target (`.applied`) did not even exist yet at this point in the sequence, so \
        a sibling's reservation would have silently succeeded with a fresh ticket 2, oblivious \
        to the torn state -- this test only passes once the merge's write-on-issuance behavior \
        is in place.
        """
    )
    func tornAuthorityRecordAfterIssuanceOnlyFailsClosedForFreshSiblingReservation() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key()

            let snapshot = try await cache.beginIssuance(for: cacheKey)
            #expect(snapshot.writeGeneration == 1)

            let name = await cache.appliedTicketFilename(for: cacheKey)
            let access = await cache.directoryAccess
            // Simulates a torn/partial write (not a clean absence) -- a
            // crash mid-`fsync` that left a truncated fragment behind
            // rather than either the old (nonexistent) or new complete
            // value.
            try access.writeTempAndFsync(tempName: name + ".tmp", data: Data("{\"issued".utf8))
            try access.renameAndFsyncDirectory(from: name + ".tmp", to: name)

            // A brand-new sibling instance over the same directory (an
            // independent process, or this same process after a
            // restart) must fail closed rather than silently reissuing
            // ticket 1 again.
            let sibling = try AssetDiskCache(directory: directory, limits: limits())
            await #expect(throws: AssetError.self) {
                _ = try await sibling.beginIssuance(for: cacheKey)
            }
        }
    }

    @Test(
        """
        The merged authority record's disposition half remains fully protected too: a \
        `.content`/`.tombstone`/`.retiring` disposition surviving alongside a corrupted -- \
        present but unparsable -- authority record still fails closed on every subsequent \
        operation, exactly like the issuance-only case above, never silently treated as a \
        pristine key.
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

            let name = await cache.appliedTicketFilename(for: cacheKey)
            let access = await cache.directoryAccess
            try access.writeTempAndFsync(tempName: name + ".tmp", data: Data("not json".utf8))
            try access.renameAndFsyncDirectory(from: name + ".tmp", to: name)

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
        A genuinely pristine key -- one that has never had any ticket issued or disposition \
        committed for it at all -- is unaffected by any of the fail-closed checks above: \
        issuance still succeeds normally, starting from ticket 1, exactly as before this \
        review round's fix
        """
    )
    func genuinelyPristineKeyIssuanceStillSucceedsNormally() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key()

            let snapshot = try await cache.beginIssuance(for: cacheKey)
            #expect(snapshot.writeGeneration == 1)
        }
    }

    @Test(
        """
        `acceptToken(_:currentEpoch:currentIssued:)` requires *exact* equality between a \
        token's own issued ticket and the currently-issued counter -- not merely `>=` -- so a \
        ticket that (through corruption this review round's other fix should already prevent \
        in practice) reports as strictly *greater* than the currently-issued counter is \
        correctly rejected rather than wrongly accepted, unlike a prior revision's `>=` compare
        """
    )
    func acceptTokenRequiresExactEqualityNotGreaterOrEqual() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let token = AssetCacheService.CacheToken(
                generation: 0,
                issuance: 0,
                durableClearEpoch: 0,
                diskWriteGeneration: 5
            )
            let exactMatch = await cache.acceptToken(token, currentEpoch: 0, currentIssued: 5)
            #expect(
                exactMatch,
                "An exact match between a token's own ticket and the current counter must pass"
            )
            let greaterThanCurrent = await cache.acceptToken(
                token,
                currentEpoch: 0,
                currentIssued: 3
            )
            #expect(
                !greaterThanCurrent,
                """
                A token whose own ticket is strictly greater than the current counter must be \
                rejected -- a prior revision's `issuedTicket >= currentIssued` compare would \
                have wrongly accepted this
                """
            )
            let behindCurrent = await cache.acceptToken(token, currentEpoch: 0, currentIssued: 7)
            #expect(
                !behindCurrent,
                "A token whose own ticket is strictly behind the current counter is rejected"
            )
        }
    }
}
