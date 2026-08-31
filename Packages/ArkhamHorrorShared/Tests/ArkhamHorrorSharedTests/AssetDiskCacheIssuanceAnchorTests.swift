@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of this review round's finding #1: a
/// key's primary/mirror authority-record pair, however faithfully
/// reconciled against *each other*
/// (`AssetDiskCache+DispositionReconciliation.swift`, and
/// `AssetDiskCacheAuthorityRecordMirrorTests.swift`'s own coverage of
/// that half), can never by itself detect a loss or rollback that
/// strikes **both** copies consistently — see
/// `AssetDiskCache+IssuanceAnchor.swift`'s own type-level doc comment
/// for the full reasoning this third, independently-named durable
/// witness closes. These tests drive
/// ``AssetDiskCache/enforceIssuanceAnchorLocked(_:for:)`` directly,
/// exactly the way ``AssetDiskCacheAuthorityRecordMirrorTests.swift``
/// drives the primary/mirror reconciliation it wraps: writing raw bytes
/// to the anchor's own on-disk name (an independent loss/rollback a
/// fault-injection hook cannot itself express, since fault injection
/// only ever intercepts this cache's own *future* writes, never a
/// pre-existing file's already-committed bytes), or fault-injecting
/// exactly the mirror's own write (the one production window that can
/// legitimately leave the anchor ahead of an otherwise internally
/// *consistent* primary/mirror pair), then reading the key's authority
/// back through the public ``AssetDiskCache/currentKeyDisposition(for:)``/
/// ``AssetDiskCache/currentKeyAuthority(for:)``/``AssetDiskCache/get(_:)``
/// surface, exactly as production code would.
///
/// **On "key pruning/recreation":** this cache has no per-key pruning
/// or recreation mechanism of any kind outside a *whole-cache*
/// ``AssetDiskCache/removeAll()`` clear (see that method's own doc
/// comment: a key's own three authority files are swept during a clear
/// alongside everything else, precisely because that clear's own epoch
/// bump already durably fences every token issued before it — there is
/// no narrower "just this one key" recreation path this cache exposes
/// anywhere). `anchorStaleEpochAfterClearIsNotBindingAndSelfHeals` below
/// is this cache's own applicable equivalent of that scenario: the
/// clear-transaction case the reviewer's own finding explicitly calls
/// out.
extension AssetDiskCacheTests {
    func anchorURL(
        directory: URL,
        cache: AssetDiskCache,
        cacheKey: AssetCacheKey
    ) async -> URL {
        let name = await cache.issuanceAnchorFilename(for: cacheKey)
        return directory.appendingPathComponent(name)
    }

    func publishInitialContent(
        cache: AssetDiskCache,
        cacheKey: AssetCacheKey,
        payload: Data
    ) async throws -> (issuance: AssetDiskCache.IssuanceSnapshot, metadata: AssetCacheMetadata) {
        let issuance = try await cache.beginIssuance(for: cacheKey)
        let token = mirrorTestToken(from: issuance)
        let entryMetadata = mirrorTestMetadata(
            for: cacheKey,
            payload: payload,
            issuance: issuance
        )
        try await cache.set(cacheKey, payload: payload, metadata: entryMetadata, token: token)
        return (issuance, entryMetadata)
    }

    @Test(
        """
        A key that has genuinely never had anything committed for it -- both copies AND its \
        own anchor all cleanly absent -- is pristine; the anchor is never itself written for a \
        key that has never had anything durably committed
        """
    )
    func genuinelyPristineKeyHasNoAnchorEither() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")

            let disposition = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(disposition.kind == .tombstone)
            #expect(disposition.ticket == 0)

            let anchorPath = await anchorURL(
                directory: directory,
                cache: cache,
                cacheKey: cacheKey
            ).path
            #expect(!FileManager.default.fileExists(atPath: anchorPath))
        }
    }

    @Test(
        """
        Both the primary and mirror copies independently lost at once (a real ticket was \
        issued, but neither surviving copy remains) must fail closed rather than resetting to \
        pristine -- the anchor alone is what makes this consistent double loss detectable. A \
        fresh sibling instance over the same directory (simulating both an independent process \
        and a restart) fails closed identically and cannot reissue the already-issued ticket.
        """
    )
    func bothCopiesLostWithSurvivingAnchorFailsClosed() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            _ = try await publishInitialContent(cache: cache, cacheKey: cacheKey, payload: payload)

            // Simulates an independent loss of *both* the primary and
            // mirror at once -- deleting byte-for-byte already-committed
            // files, exactly like `AssetDiskCacheAuthorityRecordMirrorTests`'s
            // own single-copy-loss tests, but striking both copies this
            // time. The anchor alone survives.
            try await FileManager.default.removeItem(
                at: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )
            try await FileManager.default.removeItem(
                at: mirrorURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )

            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyDisposition(for: cacheKey)
            }
            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyAuthority(for: cacheKey)
            }
            // A fresh reservation for this exact key must not be able to
            // silently reissue ticket 1 -- issuance itself reads (and is
            // gated by) the same reconciled/anchor-checked authority.
            await #expect(throws: AssetError.self) {
                _ = try await cache.beginIssuance(for: cacheKey)
            }

            // Identically fail-closed from a brand-new sibling
            // `AssetDiskCache` instance over the same directory --
            // simulating both an independent process sharing this
            // directory and this same process after a restart, sharing
            // no in-memory state with the original instance at all.
            let siblingCache = try AssetDiskCache(directory: directory, limits: smallLimits())
            await #expect(throws: AssetError.self) {
                _ = try await siblingCache.currentKeyDisposition(for: cacheKey)
            }
            await #expect(throws: AssetError.self) {
                _ = try await siblingCache.beginIssuance(for: cacheKey)
            }
        }
    }

    @Test(
        """
        Both the primary and mirror copies consistently rolled back together to a valid, \
        well-formed, but strictly older snapshot -- exactly the failure mode two copies \
        written by the same code at the same time cannot themselves distinguish from a \
        genuinely current pair -- must fail closed rather than being silently trusted merely \
        because the two copies happen to agree with each other
        """
    )
    func bothCopiesConsistentlyRolledBackFailsClosed() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            let (issuance, metadata) = try await publishInitialContent(
                cache: cache,
                cacheKey: cacheKey,
                payload: payload
            )

            // Captures the *current*, valid, well-formed snapshot of all
            // three files immediately after the initial publish -- this
            // is the "older" state both copies will be rolled back to.
            let olderPrimary = try await Data(
                contentsOf: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )
            let olderMirror = try await Data(
                contentsOf: mirrorURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )

            // A further, genuinely newer mutation for this exact key --
            // advances the anchor (and, at this instant, the primary/
            // mirror pair too) strictly ahead of the snapshot above.
            let revalidation = try #require(
                try await cache.beginRevalidationIssuance(
                    for: cacheKey,
                    expectedClearEpoch: issuance.clearEpoch,
                    expectedAppliedTicket: issuance.writeGeneration,
                    expectedContentHash: metadata.payloadSHA256Hex
                )
            )
            let refreshedPayload = Data([9, 8, 7, 6, 5])
            let refreshedToken = mirrorTestToken(from: revalidation)
            let refreshedMetadata = mirrorTestMetadata(
                for: cacheKey,
                payload: refreshedPayload,
                issuance: revalidation
            )
            try await cache.set(
                cacheKey,
                payload: refreshedPayload,
                metadata: refreshedMetadata,
                token: refreshedToken
            )

            // Rolls *both* copies back to the older, individually valid,
            // well-formed, but stale snapshot captured above -- the
            // anchor itself is left untouched, still reflecting the
            // newer publish.
            try await olderPrimary.write(
                to: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )
            try await olderMirror.write(
                to: mirrorURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )

            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyDisposition(for: cacheKey)
            }

            // No repair attempted: the older snapshot must still be
            // present afterward, completely untouched by any self-heal.
            let stillOlderPrimary = try await Data(
                contentsOf: primaryURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )
            #expect(stillOlderPrimary == olderPrimary)
        }
    }

    @Test(
        """
        A present-but-corrupt anchor with an otherwise fully valid, internally-consistent \
        primary/mirror pair must fail closed exactly like a corrupt primary/mirror copy -- an \
        untrustworthy anchor is itself active evidence, never silently ignored merely because \
        its own sibling files happen to agree with each other
        """
    )
    func corruptAnchorWithValidPairFailsClosed() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            _ = try await publishInitialContent(cache: cache, cacheKey: cacheKey, payload: payload)

            try await Data("not valid json at all".utf8).write(
                to: anchorURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )

            await #expect(throws: AssetError.self) {
                _ = try await cache.currentKeyDisposition(for: cacheKey)
            }
        }
    }

    @Test(
        """
        A missing anchor alone -- primary and mirror both present, valid, and agreeing -- is \
        the ordinary, safe case: never fails closed, and self-heals by writing a fresh, \
        current-epoch anchor so a future read has one to cross-check against
        """
    )
    func missingAnchorAloneSelfHealsWithoutFailingClosed() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            let (issuance, metadata) = try await publishInitialContent(
                cache: cache,
                cacheKey: cacheKey,
                payload: payload
            )

            try await FileManager.default.removeItem(
                at: anchorURL(directory: directory, cache: cache, cacheKey: cacheKey)
            )

            let disposition = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(disposition.kind == .content, "A missing anchor alone must never fail closed")
            #expect(disposition.contentHash == metadata.payloadSHA256Hex)
            #expect(disposition.ticket == issuance.writeGeneration)

            let hit = try await cache.get(cacheKey)
            #expect(hit?.payload == payload)

            // Self-healed: a fresh anchor must now exist, matching the
            // still-current record.
            #expect(await FileManager.default.fileExists(
                atPath: anchorURL(directory: directory, cache: cache, cacheKey: cacheKey).path
            ))
        }
    }

    @Test(
        """
        An anchor left over from before a legitimate whole-cache clear (its own recorded epoch \
        no longer matches current) is not binding: a pristine post-clear read for the same key \
        proceeds normally rather than failing closed, exactly as if the anchor were absent
        """
    )
    func anchorStaleEpochAfterClearIsNotBindingAndSelfHeals() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            _ = try await publishInitialContent(cache: cache, cacheKey: cacheKey, payload: payload)

            // Simulates "physical cleanup lags behind the epoch bump"
            // (see `AssetDiskCache+IssuanceAnchor.swift`'s own type-level
            // doc comment): the clear's own epoch bump and its removal
            // pass are still one single durable transaction from a
            // caller's point of view, but this fault deliberately leaves
            // this one key's own anchor physically behind, at its
            // pre-clear epoch, exactly the one leftover case that must
            // still resolve safely rather than wrongly failing closed.
            let anchorName = await cache.issuanceAnchorFilename(for: cacheKey)
            await cache.directoryAccess.installFaultInjection(failRemoveSuffixes: [anchorName])
            // The epoch bump itself is unconditional and lands durably
            // *before* the removal pass below (see `removeAll()`'s own
            // doc comment) — this fault only prevents this one leftover
            // file's physical removal, so `removeAll()` still throws
            // (its own contract: it must never silently under-report a
            // real removal failure), but the epoch it already durably
            // bumped is exactly the "physical cleanup lagged the epoch
            // bump" scenario this test exists to set up.
            await #expect(throws: AssetError.self) {
                try await cache.removeAll()
            }
            await cache.directoryAccess.installFaultInjection()

            #expect(await FileManager.default.fileExists(
                atPath: anchorURL(directory: directory, cache: cache, cacheKey: cacheKey).path
            ), "The fault above must have left this key's stale-epoch anchor physically behind")

            let disposition = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(
                disposition.kind == .tombstone,
                "A post-clear read for this key must proceed as genuinely pristine"
            )
            #expect(disposition.ticket == 0)

            // A fresh publish for this same key, post-clear, must
            // proceed normally -- the stale-epoch anchor must not block
            // it.
            let freshIssuance = try await cache.beginIssuance(for: cacheKey)
            let freshToken = mirrorTestToken(from: freshIssuance)
            let freshPayload = Data([5, 4, 3, 2, 1])
            let freshMetadata = mirrorTestMetadata(
                for: cacheKey,
                payload: freshPayload,
                issuance: freshIssuance
            )
            try await cache.set(
                cacheKey,
                payload: freshPayload,
                metadata: freshMetadata,
                token: freshToken
            )
            let hit = try await cache.get(cacheKey)
            #expect(hit?.payload == freshPayload)
        }
    }
}
