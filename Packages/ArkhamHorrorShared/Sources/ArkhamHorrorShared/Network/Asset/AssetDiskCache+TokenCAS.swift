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
    /// issued ticket (``AssetCacheService/CacheToken/diskWriteGeneration``)
    /// is still `>=` the highest ticket *ever reserved* for this key so
    /// far (`currentIssued`, read via
    /// ``currentIssuedTicketLocked(for:)``) — never against any
    /// actor-local, in-memory bookkeeping, and never re-read internally
    /// here (the caller reads both exactly once, so it can reuse the same
    /// values to durably commit the next applied ticket immediately after
    /// a successful mutation, without a second, potentially-inconsistent
    /// read). A `nil` on either half of `token` (a durable read failure at
    /// issuance time) always rejects; there is no in-memory fallback.
    ///
    /// **Deliberately compared against the highest *issued* ticket, not
    /// merely the highest *applied* one.** An earlier revision compared
    /// against ``currentAppliedTicketLocked(for:)`` instead — but two
    /// operations for the same key can be issued (each reserving its own
    /// ticket) in one order while completing, and therefore *applying*,
    /// in a different order: an older-issued operation A and a
    /// newer-issued operation B can both reserve their tickets before
    /// either applies, and if A's own (slower) work happens to finish and
    /// apply *before* B's, comparing only against "highest applied" would
    /// let A's own subsequent re-checks keep succeeding even after B has
    /// already been issued — a stale-but-not-yet-detected authority
    /// window. Comparing against the highest *issued* ticket instead
    /// fences A the instant B is issued, regardless of which one's
    /// network round trip or decode happens to complete, or apply, first.
    /// Since every ticket is reserved by a single, strictly-increasing,
    /// durable counter (``resolvedMutationTicketLocked(for:token:)``/
    /// ``issueTicketLocked(for:)``) and a token's own ticket can never
    /// itself exceed whatever is currently the highest-issued one, this
    /// check is in effect an *exact* match against "the single most
    /// recently issued ticket for this key, right now" — the strictest
    /// safe comparison, and exactly what a genuinely-current operation's
    /// own just-reserved ticket will always still satisfy.
    ///
    /// This is what actually makes two independently wired instances/
    /// processes sharing this same on-disk directory agree on write
    /// ordering for the same key: an older instance's delayed publish/
    /// touch/removal can never overwrite or remove state a newer
    /// instance already *issued* (whether or not that newer instance's
    /// own mutation has applied yet), regardless of which instance's own
    /// in-process bookkeeping thinks is current.
    ///
    /// Must only ever be called while the caller already holds this
    /// instance's ``SecureCacheDirectory/acquireExclusiveLock()`` — every
    /// call site (``AssetDiskCache/set(_:payload:metadata:token:)``'s
    /// `setLocked`, ``AssetDiskCache/touch(_:metadata:token:)``'s
    /// `touchLocked`, ``AssetDiskCache/remove(_:token:)``) already does.
    func acceptToken(
        _ token: AssetCacheService.CacheToken,
        currentEpoch: Int,
        currentIssued: Int
    ) -> Bool {
        guard
            let expectedEpoch = token.durableClearEpoch,
            let issuedTicket = token.diskWriteGeneration
        else {
            return false
        }
        return currentEpoch == expectedEpoch && issuedTicket >= currentIssued
    }

    /// Removes `key`'s on-disk entry only if `token` is *exactly* the
    /// token whose own mutation is currently the last-applied one for
    /// this key — i.e. the current durable disposition is *exactly*
    /// ``KeyDispositionKind/content`` at `token`'s own issued ticket —
    /// and the durable clear epoch has not changed since. Deliberately
    /// exact-match, not the `>=` compare
    /// ``acceptToken(_:currentEpoch:currentIssued:)`` uses: by the time
    /// this runs, `token`'s own mutation has already durably become the
    /// applied disposition for this key, so this only ever retracts a
    /// mutation that is still exactly the current, unsuperseded state —
    /// never a token some other, later mutation has since moved past.
    /// Mirrors ``AssetMemoryCache/removeIfApplied(_:token:)``'s
    /// exact-match semantics. Used by
    /// ``AssetCacheService/publish(_:asset:token:)``/
    /// ``AssetCacheService/touch(_:asset:token:)`` to retract a disk write
    /// that landed successfully but was only afterward discovered to
    /// already have been superseded (e.g. the last waiter of a coalesced
    /// operation cancelled before delivery).
    ///
    /// **Durably commits `.retiring(token's ticket)` before the actual
    /// metadata/payload deletion is even attempted, and `.tombstone(token's
    /// ticket)` only once that deletion has been attempted** — via
    /// ``commitRetractionLocked(for:token:destroy:)``, see that method's
    /// and `AssetDiskCache+Disposition.swift`'s own doc comments for the
    /// full crash-safety reasoning this closes. A prior revision instead
    /// reset a single bare applied-ticket counter straight to a sentinel
    /// `0` in one single write, with no intermediate durable checkpoint
    /// at all: a crash between removing the metadata pointer and
    /// committing that single write left the counter still recording the
    /// *old*, now-physically-absent content's own ticket as if it were
    /// still current — exactly the ambiguity a durable `.retiring`
    /// checkpoint, committed *first*, exists to remove. Never reserves a
    /// fresh ticket for this retraction: both disposition commits reuse
    /// `token`'s own already-issued ticket verbatim (see
    /// ``commitRetractionLocked(for:token:destroy:)``'s own doc comment
    /// for why minting a fresh one here would wrongly reject a different,
    /// concurrent, already-issued-but-not-yet-applied operation for this
    /// same key as stale).
    ///
    /// **Never retracts a disposition that is itself already a
    /// deletion/retirement rather than a live content publication.** A
    /// definitive 404 (``AssetCacheService/performRevalidation(_:)``'s
    /// `.notFound` branch, via ``AssetCacheService/invalidate(_:token:)``)
    /// durably commits `token`'s own ticket as a `.tombstone` — the
    /// correct, authoritative "this key is confirmed absent as of this
    /// ticket" disposition — and then, from this cache's own external
    /// caller's point of view, that operation's overall `Result` is a
    /// *failure* (``AssetError/candidatesExhausted``), which every
    /// coalesced waiter observes identically whether or not it was
    /// cancelled. A prior revision treated "this operation's Result was
    /// not a delivered success" as synonymous with "nothing durably
    /// applied, safe to retract" and called this method regardless — but
    /// for a definitive 404, something *was* durably, authoritatively
    /// applied (the tombstone itself), and rolling it back would erase
    /// the one piece of durable state that actually protects a stale
    /// sibling memory entry for this exact key from being served again
    /// after the origin has confirmed it gone. Distinguished here by this
    /// exact ticket's own disposition *kind*, never by whether a metadata
    /// sidecar happens to still be physically present.
    ///
    /// **Never swallows a genuine disk I/O failure as if nothing
    /// happened.** Every failure here — lock acquisition, root-authority
    /// initialization, the epoch/disposition reads, and (unlike
    /// ``remove(_:token:)``'s own, deliberately best-effort physical
    /// cleanup) the metadata `remove`/directory `fsync` performed by this
    /// method's own `destroy` closure — propagates as a typed
    /// ``AssetError`` instead: a caller that cannot confirm a retraction
    /// actually landed must not treat it as if it had (see
    /// ``AssetCacheService/retractIfApplied(_:token:)``, this method's
    /// sole production caller, for how that typed failure is recorded
    /// rather than lost). This is deliberately *not* relaxed to best-effort
    /// the way ``remove(_:token:)``'s own physical cleanup now is: a
    /// caller of this method still requires the specific, auditable
    /// "was this key's disk state actually confirmed retracted?" signal
    /// this method has always provided.
    ///
    /// Returns ``AssetCacheService/MutationOutcome/stale`` (never
    /// throwing) when `token` is no longer exactly the applied ticket for
    /// `key` — genuinely nothing to retract, not a failure — and
    /// ``AssetCacheService/MutationOutcome/applied`` once this call's own
    /// retraction (or the discovery that this exact ticket's own
    /// disposition was already a non-content kind with nothing to roll
    /// back) has durably completed.
    @discardableResult
    func removeIfApplied(
        _ key: AssetCacheKey,
        token: AssetCacheService.CacheToken
    ) async throws -> AssetCacheService.MutationOutcome {
        if let pause = testOnlyPauseBeforeAcquiringRemovalLock {
            await pause()
        }
        let lockFD = try await secureDirectory.acquireExclusiveLock()
        defer { secureDirectory.releaseExclusiveLock(lockFD) }
        try ensureRootAuthorityInitializedLocked()
        guard
            let issuedTicket = token.diskWriteGeneration,
            let issuedEpoch = token.durableClearEpoch
        else {
            return .stale
        }
        let currentEpoch = try secureDirectory.readPersistedClearEpoch()
        guard currentEpoch == issuedEpoch else { return .stale }
        let disposition = try currentDispositionLocked(for: key)
        guard disposition.ticket == issuedTicket else { return .stale }
        guard disposition.kind == .content else {
            // This exact ticket's own durable disposition is already a
            // deletion/retirement (a definitive 404's own `invalidate`
            // commit, or a previously interrupted retraction of this
            // very ticket) — see this method's own doc comment. There is
            // no live content publication left here to roll back, and
            // rewriting an already-tombstoned/retiring disposition would
            // gain nothing; simply report this retraction as already
            // satisfied.
            return .applied
        }
        try commitRetractionLocked(for: key, token: token) {
            let metadataWasPresent = try self.secureDirectory.remove(
                name: self.metadataFilename(for: key)
            )
            try self.secureDirectory.fsyncRootDirectory()
            if metadataWasPresent {
                self.cleanupSupersededPayloads(forKeyHash: key.digestHex, keeping: nil)
            }
        }
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
