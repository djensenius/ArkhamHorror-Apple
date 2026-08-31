import Foundation

/// Token compare-and-swap bookkeeping, content-hash validation, and
/// filename derivation for `AssetDiskCache`, split out of
/// `AssetDiskCache.swift` purely to stay under this package's
/// `file_length` convention.
extension AssetDiskCache {
    // MARK: - Token CAS

    /// Refuses to accept a new payload write while this cache's on-disk
    /// budget is not currently provably under control — see
    /// ``AssetDiskCache/Tombstone/markDiskWritesDisabledLocked()``'s doc
    /// comment for exactly what durably sets/clears that state.
    ///
    /// Unconditionally runs one fresh ``evictIfNeeded()`` recovery/
    /// accounting pass first — every single time this is called, not
    /// only when a disabled marker already happens to be set. This is
    /// what makes locked accounting/reservation complete *before* every
    /// publication, not merely after one: `set(_:payload:metadata:token:)`
    /// also unconditionally re-runs `evictIfNeeded()` again in its own
    /// `defer`, folding in whatever bytes that exact write itself just
    /// added — but without this call *also* running it first, the very
    /// first write ever made against a freshly-recovered, not-yet-marked-
    /// disabled directory (recovery having found some orphan/sidecar it
    /// could not confirm was actually reclaimed, or could not stat/
    /// enumerate) would sail straight past this guard (since the disabled
    /// marker only gets set *by* `evictIfNeeded()` itself, and this
    /// method previously only ever called it when the marker was already
    /// set) and publish new bytes into a directory whose true physical
    /// usage was never actually confirmed within budget beforehand at
    /// all. A marker left over from a since-resolved transient failure (a
    /// filesystem that was briefly full or read-only, for example) is not
    /// permanently stuck, either: this same fresh pass is exactly what
    /// clears it once conditions have genuinely improved, but a marker
    /// that persists even after this fresh attempt means physical usage
    /// genuinely cannot be confirmed or brought under budget right now,
    /// and this call's own new payload must not be allowed to make that
    /// unknown/over-budget state larger still.
    func requireDiskWritesEnabledLocked() throws {
        evictIfNeeded()
        guard !areDiskWritesDisabledLocked() else {
            throw AssetError.cachePersistenceFailed(
                "Disk writes are disabled: on-disk cache budget could not be confirmed"
            )
        }
    }

    /// The compare half of this cache's durable, cross-instance/cross-
    /// process per-key token CAS: accepts `token` only if its durable
    /// clear epoch still *exactly* matches the value the caller already
    /// read (under the same already-held exclusive lock) via
    /// ``SecureCacheDirectory/readPersistedClearEpoch()``, **and** its own
    /// ``AssetCacheService/CacheToken/diskAuthorityID`` is *exactly* equal
    /// to `key`'s currently-issued ``AuthorityID`` (`currentIssued`, read
    /// via ``currentIssuedAuthorityLocked(for:)``) -- never against any
    /// actor-local, in-memory bookkeeping, and never re-read internally
    /// here (the caller reads both exactly once, so it can reuse the same
    /// values to durably commit the next disposition immediately after a
    /// successful mutation, without a second, potentially-inconsistent
    /// read). A `nil` on either half of `token` (a durable read failure at
    /// issuance time) always rejects; there is no in-memory fallback.
    ///
    /// **Pure identity equality -- there is no ordering comparison, and
    /// none is possible.** Two independently minted 128-bit random
    /// identifiers have no `<`/`>=` relationship at all, which is exactly
    /// the property that makes this design non-replayable: a caller
    /// either holds the identifier this key's record currently names as
    /// issued, or it does not. An older-issued operation is fenced the
    /// instant *any* newer operation for this key is issued anywhere --
    /// in this process or a sibling one -- regardless of which one's
    /// network round trip, decode, or disk write happens to finish
    /// first, because issuance atomically replaces `issuedAuthorityID`
    /// under this same cross-process lock.
    ///
    /// **A missing or untrustworthy record fails closed here, and is
    /// never created or repaired.** `currentIssued` is read by
    /// ``currentIssuedAuthorityLocked(for:)``, which throws for a
    /// present-but-untrustworthy record and returns the reserved
    /// ``AuthorityID/pristine`` sentinel for an absent one. That sentinel
    /// can never equal a real, `SecRandomCopyBytes`-minted identifier, so
    /// an absent record rejects every token unconditionally. Only
    /// ``issueAuthorityLocked(for:)`` may ever bring a record into
    /// existence.
    ///
    /// **`transitionRevision` is deliberately not part of this compare.**
    /// The record's revision legitimately advances *between* a token's
    /// issuance and that token's own mutation -- issuance itself bumps
    /// it, a publish bumps it again, and a two-phase retraction bumps it
    /// twice more under the very same token -- so a token-captured
    /// revision would be stale by construction at nearly every mutation
    /// site. The revision's job is to order this key's own durable commit
    /// history and to let the single commit choke point
    /// (``commitAuthorityRecordLocked(_:for:)``'s checked increment)
    /// assert, defensively, that a caller computed the next revision
    /// correctly -- not to detect tampering, which
    /// `AssetDiskCache+Disposition.swift`'s "Threat model" section
    /// explicitly places out of scope.
    ///
    /// Must only ever be called while the caller already holds this
    /// instance's ``SecureCacheDirectory/acquireExclusiveLock()`` -- every
    /// call site (``AssetDiskCache/set(_:payload:metadata:token:)``'s
    /// `setLocked`, ``AssetDiskCache/touch(_:metadata:token:)``'s
    /// `touchLocked`, ``AssetDiskCache/remove(_:token:)``) already does.
    func acceptToken(
        _ token: AssetCacheService.CacheToken,
        currentEpoch: Int,
        currentIssued: AuthorityID
    ) -> Bool {
        guard
            let expectedEpoch = token.durableClearEpoch,
            let authorityID = token.diskAuthorityID
        else {
            return false
        }
        guard authorityID != .pristine else { return false }
        return currentEpoch == expectedEpoch && authorityID == currentIssued
    }

    /// Removes `key`'s on-disk entry only if `token` is *exactly* the
    /// token whose own mutation is currently the last-applied one for
    /// this key -- i.e. the current durable disposition is *exactly*
    /// ``KeyDispositionKind/content`` at `token`'s own
    /// ``AuthorityID`` -- and the durable clear epoch has not changed
    /// since. This is an exact match against `key`'s currently *applied*
    /// disposition, distinct from
    /// ``acceptToken(_:currentEpoch:currentIssued:)``'s own exact match
    /// against the currently *issued* identifier: by the time this runs,
    /// `token`'s own mutation has already durably become the applied
    /// disposition for this key, so this only ever retracts a mutation
    /// that is still exactly the current, unsuperseded state -- never one
    /// some other, later mutation has since moved past. Mirrors
    /// ``AssetMemoryCache/removeIfApplied(_:token:)``'s exact-match
    /// semantics. Used by ``AssetCacheService/publish(_:asset:token:)``/
    /// ``AssetCacheService/touch(_:asset:token:)`` to retract a disk write
    /// that landed successfully but was only afterward discovered to
    /// already have been superseded (e.g. the last waiter of a coalesced
    /// operation cancelled before delivery).
    ///
    /// **Durably commits `.retiring` before the actual metadata/payload
    /// deletion is even attempted, and `.tombstone` only once that
    /// deletion has been attempted** -- composed from
    /// ``beginRetraction(_:token:)`` (the `.retiring` commit alone)
    /// followed by ``completeRetraction(_:token:)`` (the physical
    /// deletion + final `.tombstone` commit); see each method's own doc
    /// comment, and `AssetDiskCache+Disposition.swift`'s, for the full
    /// crash-safety reasoning this closes. Never mints a fresh identifier
    /// for this retraction: both disposition commits reuse `token`'s own
    /// already-issued ``AuthorityID`` verbatim (see
    /// ``commitRetractionLocked(for:token:destroy:)``'s own doc comment
    /// for why minting a fresh one here would wrongly reject a different,
    /// concurrent, already-issued-but-not-yet-applied operation for this
    /// same key as stale).
    ///
    /// **Never retracts a disposition that is itself already a
    /// deletion/retirement rather than a live content publication.** A
    /// definitive 404 (``AssetCacheService/performRevalidation(_:)``'s
    /// `.notFound` branch, via ``AssetCacheService/invalidate(_:token:)``)
    /// durably commits `token`'s own identifier as a `.tombstone` -- the
    /// correct, authoritative "this key is confirmed absent" disposition
    /// -- and rolling that back would erase the one piece of durable
    /// state protecting a stale sibling memory entry for this exact key
    /// from being served again after the origin confirmed it gone.
    /// Distinguished here by this exact identifier's own disposition
    /// *kind*, never by whether a metadata sidecar happens to still be
    /// physically present.
    ///
    /// **Never swallows a genuine disk I/O failure as if nothing
    /// happened.** Every failure here -- lock acquisition, root-authority
    /// initialization, the epoch/disposition reads, and (unlike
    /// ``remove(_:token:)``'s own, deliberately best-effort physical
    /// cleanup) the metadata `remove`/directory `fsync`
    /// ``completeRetraction(_:token:)`` performs -- propagates as a typed
    /// ``AssetError`` instead: a caller that cannot confirm a retraction
    /// actually landed must not treat it as if it had.
    ///
    /// Returns ``AssetCacheService/MutationOutcome/stale`` (never
    /// throwing) when `token` is no longer exactly the applied identifier
    /// for `key` -- genuinely nothing to retract, not a failure -- and
    /// ``AssetCacheService/MutationOutcome/applied`` once this call's own
    /// retraction (or the discovery that this exact identifier's own
    /// disposition was already a non-content kind with nothing to roll
    /// back) has durably completed.
    @discardableResult
    func removeIfApplied(
        _ key: AssetCacheKey,
        token: AssetCacheService.CacheToken
    ) async throws -> AssetCacheService.MutationOutcome {
        let outcome = try await beginRetraction(key, token: token)
        guard outcome == .applied else { return outcome }
        try await completeRetraction(key, token: token)
        return .applied
    }

    /// `true` only for a string that is exactly 64 lowercase ASCII hex
    /// characters — the shape of a real SHA-256 hex digest, and the only
    /// shape ever safe to interpolate into a filesystem path derived from
    /// otherwise-untrusted on-disk metadata. In particular this rejects
    /// `/`, `..`, and any other path-traversal or delimiter-injection
    /// attempt a tampered metadata sidecar's `payloadSHA256Hex` field could
    /// otherwise smuggle into ``payloadFilename(keyHash:contentHash:)``.
    static func isValidContentHash(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
        }
    }
}

/// Not `private`: `AssetDiskCache+Recovery.swift` also decodes metadata
/// sidecars with this exact configuration during startup recovery.
///
/// A fresh instance per call, rather than a shared singleton, since
/// `JSONEncoder`/`JSONDecoder` are not documented as thread-safe for
/// concurrent `encode`/`decode` calls: multiple `AssetDiskCache` actor
/// instances (or concurrently running tests) could otherwise race on one
/// shared encoder/decoder's internal state. Constructing one is cheap
/// (only setting a date strategy), so this costs nothing meaningful per
/// call.
extension JSONEncoder {
    static func assetCache() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static func assetCache() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
