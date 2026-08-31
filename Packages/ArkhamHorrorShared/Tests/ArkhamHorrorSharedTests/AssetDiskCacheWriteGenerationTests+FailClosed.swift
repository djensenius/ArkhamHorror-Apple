@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of this review round's finding #2: a
/// missing/lost `.gen` (issuance-ticket counter) file must fail closed
/// whenever `key`'s own surviving disposition proves a ticket was
/// genuinely issued and applied for it at some point -- never silently
/// collapse back to the same zero baseline a truly pristine key would
/// also report (see `AssetDiskCache+WriteGeneration.swift`'s
/// `currentIssuedTicketLocked(for:)` doc comment for the full
/// reasoning). Split out of `AssetDiskCacheWriteGenerationTests.swift`
/// purely to keep that file within this package's `file_length`/
/// `type_body_length` conventions; reuses that file's own
/// `withScratchDirectory`/`limits`/`key`/`metadata`/`issuedToken`
/// helpers.
extension AssetDiskCacheWriteGenerationTests {
    // MARK: - Missing/lost `.gen` counter fail-closed (review round: HIGH #2)

    @Test(
        """
        A `.gen` (issuance-ticket counter) file lost or corrupted independently of `key`'s own \
        surviving `.content` disposition must fail closed on every operation that consults it \
        -- never silently collapse back to the same zero baseline a genuinely pristine key \
        reports, which would let a delayed/replayed ticket wrongly satisfy a fresh \
        issuance/CAS check and overwrite or retract content a strictly newer ticket already \
        durably owns
        """
    )
    func missingGenerationCounterWithSurvivingContentDispositionFailsClosed() async throws {
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
            let dispositionBeforeLoss = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(dispositionBeforeLoss.kind == .content)
            #expect(dispositionBeforeLoss.ticket == publishToken.diskWriteGeneration)

            // Simulates the `.gen` counter file being independently lost
            // or corrupted -- never a legitimate outcome for a key whose
            // own disposition still durably records a ticket that was
            // once actually issued (only `removeAll()` ever legitimately
            // removes both files together, always paired with a durable
            // clear-epoch bump; see this file's own type-level doc
            // comment).
            _ = try await cache.directoryAccess.remove(
                name: cache.writeGenerationFilename(for: cacheKey)
            )

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

            // Fail-closed here means "refuse to issue/mutate further,"
            // never "destroy what is already there": the original
            // content itself, and its disposition, remain completely
            // untouched by every one of the above rejected attempts.
            let dispositionAfterFailures = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(dispositionAfterFailures == dispositionBeforeLoss)
            let hit = try await cache.get(cacheKey)
            #expect(hit?.payload == payload)
        }
    }

    @Test(
        """
        A `.gen` file lost independently of `key`'s own surviving `.tombstone` disposition \
        (a completed, definitive removal) must fail closed identically to the `.content` case \
        -- a tombstoned key is not "pristine," and must not be allowed to silently re-admit a \
        delayed ticket issued before its own removal
        """
    )
    func missingGenerationCounterWithSurvivingTombstoneDispositionFailsClosed() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key()

            let publishToken = try await issuedToken(from: cache, for: cacheKey)
            let payload = Data([3, 3, 3])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload),
                token: publishToken
            )
            try await cache.remove(cacheKey, token: nil)
            let dispositionBeforeLoss = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(dispositionBeforeLoss.kind == .tombstone)
            #expect(dispositionBeforeLoss.ticket > 0)

            _ = try await cache.directoryAccess.remove(
                name: cache.writeGenerationFilename(for: cacheKey)
            )

            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: cacheKey)
            }

            let dispositionAfterFailure = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(dispositionAfterFailure == dispositionBeforeLoss)
        }
    }

    @Test(
        """
        A `.gen` file lost independently of `key`'s own surviving `.retiring` disposition (a \
        retraction whose durable phase-1 commit landed but whose physical cleanup has not yet \
        run) must fail closed exactly like the `.content`/`.tombstone` cases -- `.retiring` is \
        already unreadable to `get(_:)`, but a lost counter here must still never let a fresh \
        issuance silently resume from zero
        """
    )
    func missingGenerationCounterWithSurvivingRetiringDispositionFailsClosed() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: limits())
            let cacheKey = try key()

            let publishToken = try await issuedToken(from: cache, for: cacheKey)
            let payload = Data([5, 5, 5])
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: metadata(for: cacheKey, payload: payload),
                token: publishToken
            )
            // Durably commits `.retiring` alone, deliberately never
            // completing phase 2 -- see `AssetDiskCache+TokenCAS.swift`'s
            // `beginRetraction(_:token:)`/`completeRetraction(_:token:)`
            // doc comments for why phase 1 alone already leaves this key
            // unreadable.
            let beginOutcome = try await cache.beginRetraction(cacheKey, token: publishToken)
            #expect(beginOutcome == .applied)
            let dispositionBeforeLoss = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(dispositionBeforeLoss.kind == .retiring)
            #expect(dispositionBeforeLoss.ticket == publishToken.diskWriteGeneration)

            _ = try await cache.directoryAccess.remove(
                name: cache.writeGenerationFilename(for: cacheKey)
            )

            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: cacheKey)
            }

            let dispositionAfterFailure = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(dispositionAfterFailure == dispositionBeforeLoss)
        }
    }

    @Test(
        """
        A genuinely pristine key -- one that has never had any ticket issued or disposition \
        committed for it at all -- is unaffected by the fail-closed cross-check above: issuance \
        still succeeds normally, starting from ticket 1, exactly as before this review round's \
        fix
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
