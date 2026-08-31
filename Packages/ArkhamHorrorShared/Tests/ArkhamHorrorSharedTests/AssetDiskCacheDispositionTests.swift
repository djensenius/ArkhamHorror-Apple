@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Deterministic reproduction of the durable typed per-key disposition
/// model (`AssetDiskCache+Disposition.swift`) this review round's two
/// HIGH findings required:
///
/// - **Finding #1**: retraction authority must be durable, not
///   process-local, and must never let a since-retracted publication be
///   mistaken for still-current merely because a stale historical stamp's
///   ticket number happens to coincide with the retracted disposition's
///   own unchanged ticket.
/// - **Finding #2**: a failed conditional-404 deletion must never be
///   reported `.applied` -- the disposition-commit transaction itself,
///   not mere physical cleanup, is what determines success.
///
/// Reuses `AssetDiskCacheTests`'s `withScratchDirectory`/`key`/
/// `metadata`/`smallLimits` helpers, exactly like every other split-out
/// `AssetDiskCache*Tests.swift` file.
extension AssetDiskCacheTests {
    /// Constructs a `CacheToken` carrying exactly `snapshot`'s durable
    /// authority, as `quarantineDiskHit`/`resolveOrIssueRevalidation`
    /// both do in production -- but constructed directly here so these
    /// tests can drive ``AssetDiskCache`` alone, with no
    /// ``AssetCacheService`` involved at all, exactly reproducing a
    /// token-gated `set`/`removeIfApplied` pair the way a single
    /// coalesced fetch operation would issue and later retract its own
    /// publication.
    private func token(
        from snapshot: AssetDiskCache.IssuanceSnapshot
    ) -> AssetCacheService.CacheToken {
        AssetCacheService.CacheToken(
            generation: 0,
            issuance: 0,
            durableClearEpoch: snapshot.clearEpoch,
            diskWriteGeneration: snapshot.writeGeneration
        )
    }

    /// `metadata(for:payload:)`'s own `clearEpochAtPublication`/
    /// `writeGenerationAtPublication` default to `0` -- fine for tests
    /// that never touch the disposition model, but ``getLocked``'s own
    /// disposition cross-check requires `writeGenerationAtPublication`
    /// to exactly equal whatever ticket this disk cache's own
    /// `commitPublicationLocked(for:token:contentHash:)` actually commits
    /// for this exact write (see that method's doc comment): in
    /// production, ``AssetCacheService`` always stamps this itself
    /// before ever calling ``AssetDiskCache/set(_:payload:metadata:token:)``.
    /// These tests drive ``AssetDiskCache`` directly with no
    /// ``AssetCacheService`` involved at all, so this helper stamps the
    /// same two fields from `issuance` (the exact snapshot `token(from:)`
    /// above also derives its token from) to keep every publish in this
    /// file internally consistent, exactly like production.
    private func publishedMetadata(
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

    @Test(
        """
        A retraction's own disposition durably reuses its content's exact ticket -- so a stale \
        cached entry's historical stamp can coincide with a since-retracted disposition's \
        ticket number. beginRevalidationIssuance must still reject it, even when both the \
        ticket AND the content hash exactly match, because the durable disposition kind is no \
        longer `.content`. This is the concrete resurrection scenario finding #1 identified: a \
        bare ticket-only (or ticket+hash-only) provenance check is unsound on its own once a \
        retraction can reuse its own content's exact ticket.
        """
    )
    func retractedTicketCannotBeMistakenForCurrentDespiteExactHashMatch() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])

            let issuance = try await cache.beginIssuance(for: cacheKey)
            let publishToken = token(from: issuance)
            let entryMetadata = publishedMetadata(
                for: cacheKey,
                payload: payload,
                issuance: issuance
            )
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: entryMetadata,
                token: publishToken
            )

            let dispositionAfterPublish = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(dispositionAfterPublish.kind == .content)
            #expect(dispositionAfterPublish.ticket == issuance.writeGeneration)
            #expect(dispositionAfterPublish.contentHash == entryMetadata.payloadSHA256Hex)

            // Confirms the entry is genuinely servable before retraction
            // -- so the later `hit == nil` assertion actually proves the
            // retraction/disposition mismatch caused the miss, not a
            // pre-existing, unrelated stamping problem.
            let hitBeforeRetraction = try await cache.get(cacheKey)
            #expect(hitBeforeRetraction?.payload == payload)

            // Retracts exactly this publication -- reusing its own
            // already-accepted ticket verbatim, never a fresh one (see
            // `removeIfApplied(_:token:)`'s own doc comment).
            let retractOutcome = try await cache.removeIfApplied(cacheKey, token: publishToken)
            #expect(retractOutcome == .applied)

            let dispositionAfterRetraction = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(dispositionAfterRetraction.kind == .tombstone)
            #expect(
                dispositionAfterRetraction.ticket == issuance.writeGeneration,
                "The retraction must reuse the exact same ticket its own content was published"
            )

            // The critical assertion: a stale cached entry whose own
            // historical stamp captured this exact publication (same
            // ticket, same content hash) must not be able to pass a
            // fresh revalidation issuance check now that this exact
            // ticket's disposition has since been retracted.
            let staleRevalidation = try await cache.beginRevalidationIssuance(
                for: cacheKey,
                expectedClearEpoch: issuance.clearEpoch,
                expectedAppliedTicket: issuance.writeGeneration,
                expectedContentHash: entryMetadata.payloadSHA256Hex
            )
            #expect(
                staleRevalidation == nil,
                """
                A since-retracted disposition must never be mistaken for still-current \
                content merely because a stale historical stamp's ticket (and even its \
                content hash) happens to coincide with the retraction's own unchanged ticket
                """
            )

            // `get(_:)` itself must independently refuse to serve this
            // entry too -- the disk-level read-time disposition gate,
            // not merely the revalidation-issuance gate.
            let hit = try await cache.get(cacheKey)
            #expect(hit == nil)
        }
    }

    @Test(
        """
        A crash (simulated here as a failed physical deletion) between removeIfApplied's own \
        durable `.retiring` commit and its `.tombstone` commit leaves the disposition durably \
        stuck at `.retiring` -- unreadable exactly like a confirmed tombstone, in this same \
        process, in a brand-new sibling instance over the same directory (simulating both an \
        independent process and a restart), and self-healing the instant a later mutation for \
        this exact key durably lands.
        """
    )
    func stuckRetiringDispositionIsUnreadableAcrossRestartAndSelfHeals() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])

            let issuance = try await cache.beginIssuance(for: cacheKey)
            let publishToken = token(from: issuance)
            let entryMetadata = publishedMetadata(
                for: cacheKey,
                payload: payload,
                issuance: issuance
            )
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: entryMetadata,
                token: publishToken
            )

            // Fails exactly the metadata-pointer physical removal
            // `removeIfApplied(_:token:)`'s own `destroy` closure
            // performs -- unlike `remove(_:token:)`, that closure still
            // *propagates* this failure (see its own doc comment), so it
            // escapes `commitRetractionLocked` after the `.retiring`
            // commit has already durably landed but strictly before the
            // final `.tombstone` commit is ever attempted -- precisely
            // simulating a crash in that exact window.
            let metadataName = await cache.metadataFilename(for: cacheKey)
            await cache.directoryAccess.installFaultInjection(failRemoveSuffixes: [metadataName])
            await #expect(throws: AssetError.self) {
                try await cache.removeIfApplied(cacheKey, token: publishToken)
            }

            let stuckDisposition = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(stuckDisposition.kind == .retiring)
            #expect(stuckDisposition.ticket == issuance.writeGeneration)

            // Unreadable in this exact same process/instance, with no
            // restart at all.
            let hitBeforeRestart = try await cache.get(cacheKey)
            #expect(hitBeforeRestart == nil)

            // Unreadable from a brand-new sibling `AssetDiskCache`
            // instance over the same directory too -- simulating both an
            // independent process sharing this directory and this same
            // process after a restart, sharing no in-memory state with
            // the original instance at all.
            let siblingCache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let siblingHit = try await siblingCache.get(cacheKey)
            #expect(siblingHit == nil)

            // Self-heals the instant a fresh, unrelated mutation for this
            // exact key durably lands. Uses an explicit token/issuance
            // here too (rather than an unconditional `set`) purely so the
            // committed ticket is known in advance and the healed
            // entry's own metadata can be stamped to match it -- an
            // unconditional `set`'s freshly *self*-reserved ticket would
            // be just as durably correct in production (where
            // ``AssetCacheService`` always stamps a fresh `beginIssuance`
            // snapshot into its own metadata before publishing), this is
            // purely a test-construction convenience.
            let healingIssuance = try await siblingCache.beginIssuance(for: cacheKey)
            let healingToken = token(from: healingIssuance)
            let healedPayload = Data([9, 9, 9, 9, 9])
            let healedMetadata = publishedMetadata(
                for: cacheKey,
                payload: healedPayload,
                issuance: healingIssuance
            )
            try await siblingCache.set(
                cacheKey,
                payload: healedPayload,
                metadata: healedMetadata,
                token: healingToken
            )
            let healedHit = try await siblingCache.get(cacheKey)
            #expect(healedHit?.payload == healedPayload)
            let healedDisposition = try await siblingCache.currentKeyDisposition(for: cacheKey)
            #expect(healedDisposition.kind == .content)
        }
    }

    @Test(
        """
        A genuine disposition-commit failure during remove(_:) -- not merely a best-effort \
        physical-deletion failure -- leaves the prior entry's own disposition and content \
        completely untouched: nothing is torn down before the durable transaction itself has \
        actually landed, so a caller observing the thrown error can safely treat this exactly \
        like a call that was never attempted, never like a partial or ambiguous removal.
        """
    )
    func failedDispositionCommitDuringDefinitiveRemovalLeavesPriorEntryFullyIntact() async throws {
        try await withScratchDirectory { directory in
            let cache = try AssetDiskCache(directory: directory, limits: smallLimits())
            let cacheKey = try key("01001")
            let payload = Data([1, 2, 3, 4, 5])
            let issuance = try await cache.beginIssuance(for: cacheKey)
            let publishToken = token(from: issuance)
            let entryMetadata = publishedMetadata(
                for: cacheKey,
                payload: payload,
                issuance: issuance
            )
            try await cache.set(
                cacheKey,
                payload: payload,
                metadata: entryMetadata,
                token: publishToken
            )

            // Fails the disposition file's own temp write (`.applied.tmp`)
            // -- the very first durable operation `commitRetractionLocked`
            // performs, strictly before its `destroy` closure (the actual
            // physical deletion attempt) is ever invoked.
            await cache.directoryAccess.installFaultInjection(failSuffixes: [".applied"])
            await #expect(throws: AssetError.self) {
                try await cache.remove(cacheKey)
            }

            // Nothing was disturbed: the original content is still fully
            // intact and servable, exactly as if `remove(_:)` had never
            // been called at all.
            let disposition = try await cache.currentKeyDisposition(for: cacheKey)
            #expect(disposition.kind == .content)
            let hit = try await cache.get(cacheKey)
            #expect(hit?.payload == payload)
        }
    }
}
